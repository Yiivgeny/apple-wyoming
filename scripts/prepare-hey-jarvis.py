#!/usr/bin/env python3
"""Prepare the upstream hey_jarvis ONNX classifier for LiveKitWakeWord.

Development-only usage:
  uv run --with onnx python scripts/prepare-hey-jarvis.py \
    --input hey_jarvis_v0.1.onnx \
    --output Sources/WakeWord/Resources/hey_jarvis.onnx

The upstream graph already consumes the expected ``(1, 16, 96)`` embedding
tensor and produces a scalar score. This script only gives those tensors the
``embeddings`` and ``score`` names required by LiveKitWakeWord's Swift wrapper.
The runtime service does not invoke Python.
"""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path

import onnx


EXPECTED_ONNX_SHA256 = "94a13cfe60075b132f6a472e7e462e8123ee70861bc3fb58434a73712ee0d2cb"
EXPECTED_INPUT_NAME = "x.1"
EXPECTED_OUTPUT_NAME = "53"


def rename_value(graph: onnx.GraphProto, old_name: str, new_name: str) -> None:
    for value in (*graph.input, *graph.output, *graph.value_info):
        if value.name == old_name:
            value.name = new_name
    for initializer in graph.initializer:
        if initializer.name == old_name:
            initializer.name = new_name
    for node in graph.node:
        for index, name in enumerate(node.input):
            if name == old_name:
                node.input[index] = new_name
        for index, name in enumerate(node.output):
            if name == old_name:
                node.output[index] = new_name
        for attribute in node.attribute:
            if attribute.type == onnx.AttributeProto.GRAPH:
                rename_value(attribute.g, old_name, new_name)
            elif attribute.type == onnx.AttributeProto.GRAPHS:
                for child_graph in attribute.graphs:
                    rename_value(child_graph, old_name, new_name)


def prepare(source: Path, destination: Path) -> None:
    source_bytes = source.read_bytes()
    actual_sha256 = hashlib.sha256(source_bytes).hexdigest()
    if actual_sha256 != EXPECTED_ONNX_SHA256:
        raise ValueError(
            f"unexpected hey_jarvis_v0.1.onnx SHA-256: {actual_sha256}; "
            f"expected {EXPECTED_ONNX_SHA256}"
        )

    model = onnx.load_from_string(source_bytes)
    if len(model.graph.input) != 1 or model.graph.input[0].name != EXPECTED_INPUT_NAME:
        raise ValueError("unexpected hey_jarvis input tensor")
    if len(model.graph.output) != 1 or model.graph.output[0].name != EXPECTED_OUTPUT_NAME:
        raise ValueError("unexpected hey_jarvis output tensor")

    rename_value(model.graph, EXPECTED_INPUT_NAME, "embeddings")
    rename_value(model.graph, EXPECTED_OUTPUT_NAME, "score")
    model.producer_name = "AppleWyoming hey_jarvis preparer"
    model.doc_string = (
        "hey_jarvis v0.1 openWakeWord classifier with LiveKitWakeWord-compatible "
        "input and output tensor names"
    )
    onnx.checker.check_model(model)
    destination.parent.mkdir(parents=True, exist_ok=True)
    onnx.save(model, destination)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()
    prepare(arguments.input, arguments.output)


if __name__ == "__main__":
    main()
