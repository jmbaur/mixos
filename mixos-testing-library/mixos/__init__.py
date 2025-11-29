from schema import Schema
from typing import TypedDict
import json
import logging
import socket
import subprocess
import threading

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


class Machine:
    def __init__(self, *args, **kwargs):
        """
        Creates a new MixOS Machine

        All args and kwargs are passed to `socket.create_connection()`.
        """
        self.create_connection_args = args
        self.create_connection_kwargs = kwargs
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

    def connect(self):
        retries = 0
        while True:
            try:
                logger.debug("attempting connection")
                self.sock = socket.create_connection(
                    *self.create_connection_args, **self.create_connection_kwargs
                )
                return
            except OSError as e:
                logger.info("connection failed, retrying")
                retries += 1
                if retries > 10:
                    raise e

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


class VirtualMachine(Machine):
    def __init__(self, kernel: str, initrd: str, append: str):
        super().__init__(("localhost", 8000))
        self.process = subprocess.Popen(
            f"qemu-system-x86_64 -enable-kvm -machine q35 -m 2G -nographic -device \"e1000,netdev=net0\" -netdev \"user,id=net0,hostfwd=tcp::8000-:8000\" -kernel {kernel} -initrd {initrd} -append \"{append}\"",
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            shell=True,
            # cwd=state_dir,
            # env=self.build_environment(state_dir, shared_dir),
        )

        def process_serial_output() -> None:
            assert self.process
            assert self.process.stdout
            for _line in self.process.stdout:
                # Ignore undecodable bytes that may occur in boot menus
                line = _line.decode(errors="ignore").replace("\r", "").rstrip()
                print(line)

        self.serial_thread = threading.Thread(target=process_serial_output)
        self.serial_thread.start()
