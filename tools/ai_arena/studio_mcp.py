"""A small client for Roblox Studio's MCP server (the one Studio's assistant installs as mcp.bat), over stdio, for tools
that drive an open Studio: see replay.py.

    session = StudioSession()            # starts the server
    studio_id = session.game_studio()    # the Studio window with the game place open
    session.call("execute_luau", {"studio_id": studio_id, "datamodel_type": "Edit", "code": "return 1"})
    session.close()
"""

from __future__ import annotations

import json
import os
import subprocess
from typing import Any

MCP = os.path.expandvars(r"%LOCALAPPDATA%\Roblox\mcp.bat")
# the game place (rts-game.project.json); the lobby is another
GAME_PLACE_ID = "114890272627009"


class StudioSession:
    def __init__(self) -> None:
        if not os.path.exists(MCP):
            raise RuntimeError(f"Roblox Studio's MCP server is not installed ({MCP} is missing)")
        self.process = subprocess.Popen(
            ["cmd.exe", "/c", MCP],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            encoding="utf-8",
        )
        self.next_id = 0
        self.request("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                                    "clientInfo": {"name": "rts-tools", "version": "1"}})
        self.notify("notifications/initialized")

    def notify(self, method: str) -> None:
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "method": method}) + "\n")
        self.process.stdin.flush()

    def request(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        self.next_id += 1
        message = {"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params}
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()
        while True:
            line = self.process.stdout.readline()
            if not line:
                raise RuntimeError("Studio's MCP server closed")
            try:
                reply = json.loads(line)
            except json.JSONDecodeError:
                continue
            if reply.get("id") == self.next_id:
                if "error" in reply:
                    raise RuntimeError(f"{method}: {reply['error']}")
                return reply["result"]

    def call(self, tool: str, arguments: dict[str, Any]) -> str:
        """A tool's text output."""
        result = self.request("tools/call", {"name": tool, "arguments": arguments})
        text = " ".join(item.get("text", "") for item in result.get("content", []))
        if result.get("isError"):
            raise RuntimeError(f"{tool}: {text}")
        return text

    def game_studio(self) -> str:
        """The id of the Studio window that has the game place open."""
        studios = json.loads(self.call("list_roblox_studios", {}))["studios"]
        for studio in studios:
            if GAME_PLACE_ID in (studio.get("name") or ""):
                return studio["id"]
        raise RuntimeError(f"no Studio has the game place ({GAME_PLACE_ID}) open: {studios}")

    def close(self) -> None:
        self.process.kill()
