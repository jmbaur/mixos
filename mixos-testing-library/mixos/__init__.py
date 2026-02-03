from schema import Schema
from typing import TypedDict
import json
import logging
import socket
from enum import Enum
import os


logger = logging.getLogger(__name__)


run_command_schema = Schema(
    {
        "exit_code": int,
        "stdout": [int],
        "stderr": [int],
    }
)


class RunCommandResult(TypedDict):
    exit_code: int
    stdout: list[int]
    stderr: list[int]


class Protocol(Enum):
    INET = 1
    UNIX = 2
    VSOCK = 3


class Machine:
    def __init__(self, conn):
        """
        Creates a new MixOS Machine
        """
        self.conn = Machine._parse_connection_string(conn)
        self.sock = None

    def __enter__(self):
        self.connect()
        return self

    def __exit__(self, type, value, traceback):
        _ = type
        _ = value
        _ = traceback

        if self.sock is not None:
            self.sock.__exit__()

    @staticmethod
    def _parse_connection_string(conn: str):
        if conn.startswith("vsock:"):
            split = conn[len("vsock:") :].split(":", maxsplit=1)
            assert len(split) == 2
            cid = int(split[0])
            port = int(split[1])
            return (Protocol.VSOCK, (cid, port))
        elif conn.startswith(os.path.sep):
            return (Protocol.UNIX, conn)
        else:
            split = conn.rsplit(":", maxsplit=1)
            assert len(split) == 2
            ip = split[0].strip("[]")
            port = int(split[1])
            return (Protocol.INET, (ip, port))

    def connect(self):
        match self.conn[0]:
            case Protocol.VSOCK:
                logger.debug(f"connecting to vsock host {self.conn[1]}")
                self.sock = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
                self.sock.connect(self.conn[1])
            case Protocol.UNIX:
                logger.debug(f"connection to unix domain socket host {self.conn[1]}")
                self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                self.sock.connect(self.conn[1])
            case Protocol.INET:
                logger.debug(f"connecting to inet host {self.conn[1]}")
                self.sock = socket.create_connection(self.conn[1])

    def recv_message(self):
        assert self.sock is not None

        buf = bytearray()

        while True:
            data = self.sock.recv(1 << 16)
            if not data:
                raise EOFError("socket closed")

            buf_len = len(buf)
            buf.extend(data)

            null_index = data.find(0)
            if null_index >= 0:
                raw_response = bytes(buf[: buf_len + null_index])
                break

        logger.debug("message from machine: {}".format(raw_response))
        response = json.loads(raw_response)
        if "error" in response:
            raise Exception(response["error"])

        return response["result"]

    def run_command(self, command: list[str]) -> RunCommandResult:
        assert self.sock is not None
        if len(command) == 0:
            raise ValueError("empty command")
        self.sock.send(json.dumps({"run_command": {"command": command}}).encode())
        self.sock.send("\0".encode())
        response = self.recv_message()
        valid = run_command_schema.validate(response["run_command"])
        return RunCommandResult(valid)
