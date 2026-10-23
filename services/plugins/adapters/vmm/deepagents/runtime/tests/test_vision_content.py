"""Platform file_read image markers become vision content the agent can see."""

from __future__ import annotations

import json

from aseman_agents.tools import _as_vision_content


def test_multimodal_marker_becomes_image_blocks() -> None:
    marker = json.dumps({
        "__multimodal": {
            "text": "file: sandbox /workspace/ui-phone.png — screenshot",
            "image_url": "data:image/jpeg;base64,AAAA",
        }
    })
    blocks = _as_vision_content(marker)
    assert isinstance(blocks, list)
    assert blocks[0] == {"type": "text", "text": "file: sandbox /workspace/ui-phone.png — screenshot"}
    assert blocks[1]["type"] == "image_url"
    assert blocks[1]["image_url"]["url"].startswith("data:image/jpeg;base64,")


def test_plain_text_is_unchanged() -> None:
    assert _as_vision_content("hello") == "hello"
    assert _as_vision_content('{"ok": true}') == '{"ok": true}'
