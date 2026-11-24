#!/usr/bin/env python3
"""Rebuild the bundled okay_nabu ONNX classifier from the upstream TFLite weights.

Development-only usage:
  uv run --with tflite --with onnx python scripts/convert-okay-nabu.py \
    --input okay_nabu.tflite \
    --output Sources/WakeWord/Resources/okay_nabu.onnx

The runtime service does not invoke Python or TensorFlow Lite.
"""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path

import numpy as np
import onnx
from onnx import TensorProto, helper, numpy_helper
import tflite


EXPECTED_TFLITE_SHA256 = "2982cecde4ee81cc7a2573d2602a7d54f0669425c94a7b64af77e0ff92b03a18"


def convert(source: Path, destination: Path) -> None:
    source_bytes = source.read_bytes()
    actual_sha256 = hashlib.sha256(source_bytes).hexdigest()
    if actual_sha256 != EXPECTED_TFLITE_SHA256:
        raise ValueError(
            f"unexpected okay_nabu.tflite SHA-256: {actual_sha256}; "
            f"expected {EXPECTED_TFLITE_SHA256}"
        )

    tflite_model = tflite.Model.GetRootAsModel(source_bytes, 0)
    graph = tflite_model.Subgraphs(0)

    def tensor(index: int) -> np.ndarray:
        metadata = graph.Tensors(index)
        buffer = tflite_model.Buffers(metadata.Buffer())
        raw = buffer.DataAsNumpy().tobytes()
        dtype = {
            tflite.TensorType.FLOAT32: np.float32,
            tflite.TensorType.INT32: np.int32,
        }[metadata.Type()]
        shape = [metadata.Shape(i) for i in range(metadata.ShapeLength())]
        return np.frombuffer(raw, dtype=dtype).reshape(shape)

    weights1, weights2, weights3 = (tensor(index) for index in (11, 12, 13))
    bias1, bias2, bias3 = (tensor(index) for index in (4, 7, 10))
    gamma1, beta1, gamma2, beta2 = (tensor(index) for index in (5, 6, 8, 9))
    epsilon = np.array(float(tensor(2)), dtype=np.float32)

    initializers = [
        numpy_helper.from_array(value, name)
        for name, value in (
            ("shape", np.array([1, 16 * 96], dtype=np.int64)),
            ("weights1", weights1),
            ("bias1", bias1),
            ("gamma1", gamma1),
            ("beta1", beta1),
            ("epsilon", epsilon),
            ("weights2", weights2),
            ("bias2", bias2),
            ("gamma2", gamma2),
            ("beta2", beta2),
            ("weights3", weights3),
            ("bias3", bias3),
        )
    ]

    nodes: list[onnx.NodeProto] = []

    def add(op_type: str, inputs: list[str], outputs: list[str], **attributes: object) -> None:
        nodes.append(helper.make_node(op_type, inputs, outputs, **attributes))

    def add_layer_norm(prefix: str, input_name: str, gamma: str, beta: str) -> str:
        add("ReduceMean", [input_name], [f"{prefix}_mean"], axes=[1], keepdims=1)
        add("Sub", [input_name, f"{prefix}_mean"], [f"{prefix}_centered"])
        add(
            "Mul",
            [f"{prefix}_centered", f"{prefix}_centered"],
            [f"{prefix}_squared"],
        )
        add(
            "ReduceMean",
            [f"{prefix}_squared"],
            [f"{prefix}_variance"],
            axes=[1],
            keepdims=1,
        )
        add("Add", [f"{prefix}_variance", "epsilon"], [f"{prefix}_variance_epsilon"])
        add("Sqrt", [f"{prefix}_variance_epsilon"], [f"{prefix}_stddev"])
        add("Div", [f"{prefix}_centered", f"{prefix}_stddev"], [f"{prefix}_unit"])
        add("Mul", [f"{prefix}_unit", gamma], [f"{prefix}_scaled"])
        add("Add", [f"{prefix}_scaled", beta], [f"{prefix}_normalized"])
        output_name = f"{prefix}_relu"
        add("Relu", [f"{prefix}_normalized"], [output_name])
        return output_name

    add("Reshape", ["embeddings", "shape"], ["flat"])
    add("Gemm", ["flat", "weights1", "bias1"], ["dense1"], transB=1)
    relu1 = add_layer_norm("layer1", "dense1", "gamma1", "beta1")
    add("Gemm", [relu1, "weights2", "bias2"], ["dense2"], transB=1)
    relu2 = add_layer_norm("layer2", "dense2", "gamma2", "beta2")
    add("Gemm", [relu2, "weights3", "bias3"], ["logit"], transB=1)
    add("Sigmoid", ["logit"], ["score"])

    onnx_graph = helper.make_graph(
        nodes,
        "okay_nabu",
        [helper.make_tensor_value_info("embeddings", TensorProto.FLOAT, [1, 16, 96])],
        [helper.make_tensor_value_info("score", TensorProto.FLOAT, [1, 1])],
        initializers,
    )
    model = helper.make_model(
        onnx_graph,
        producer_name="AppleWyoming okay_nabu converter",
        opset_imports=[helper.make_opsetid("", 17)],
    )
    model.ir_version = 9
    model.doc_string = (
        "okay_nabu openWakeWord classifier converted from "
        "rhasspy/pyopen-wakeword TFLite weights"
    )
    onnx.checker.check_model(model)
    destination.parent.mkdir(parents=True, exist_ok=True)
    onnx.save(model, destination)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()
    convert(arguments.input, arguments.output)


if __name__ == "__main__":
    main()
