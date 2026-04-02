from argparse import ArgumentParser, REMAINDER
from enum import Enum
import logging
import logging
import os
import socket
import varlink


logger = logging.getLogger(__name__)


class Protocol(Enum):
    TCP = 1
    UNIX = 2
    VSOCK = 3


class Machine(varlink.SimpleClientInterfaceHandler):
    def __init__(self, conn):
        """
        Creates a new MixOS Machine
        """
        self._conn = Machine._parse_connection_string(conn)
        self.client = None
        self.interface = None

    def __enter__(self):
        self._connect()
        return self

    def __exit__(self, type, value, traceback):
        if self.client is not None:
            self.client.__exit__(type, value, traceback)

        # NOTE: The varlink interface has ownership of the socket, so
        # we do not close the socket ourselves.
        if self.interface is not None:
            self.interface.__exit__(type, value, traceback)

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
            return (Protocol.TCP, (ip, port))

    def _connect(self):
        assert self._conn is not None

        match self._conn[0]:
            case Protocol.VSOCK:
                logger.debug(f"connecting to vsock host {self._conn[1]}")
                sock = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
                sock.connect(self._conn[1])
            case Protocol.UNIX:
                logger.debug(f"connection to unix domain socket host {self._conn[1]}")
                sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                sock.connect(self._conn[1])
            case Protocol.TCP:
                logger.debug(f"connecting to TCP host {self._conn[1]}")
                sock = socket.create_connection(self._conn[1])

        interface_name = "com.jmbaur.mixos"
        client = varlink.Client()
        if interface_name not in client._interfaces:
            client.get_interface(interface_name, socket_connection=sock)

        if interface_name not in client._interfaces:
            raise varlink.InterfaceNotFound(interface_name)

        super().__init__(client._interfaces[interface_name], sock, namespaced=False)


def cli():
    parser = ArgumentParser()
    parser.add_argument(
        "-d",
        "--debug",
        action="store_true",
        help="Enable verbose logging",
        default=False,
    )
    parser.add_argument(
        "-a",
        "--address",
        type=str,
        required=True,
        help="Address of the MixOS machine, of the form <ipv4>:<port>, [<ipv6>]:<port>, or vsock:<cid>:<port>",
    )
    parser.add_argument(
        "command",
        type=str,
        nargs=REMAINDER,
        help="Command to run on MixOS machine",
    )
    args = parser.parse_args()

    logging.basicConfig(level=logging.DEBUG if args.debug else logging.INFO)

    with Machine(args.address) as machine:
        response = machine.RunCommand(args.command)
        print("\nstdout:\n{}".format(response["stdout"].strip()))
        print("\nstderr:\n{}".format(response["stderr"].strip()))
        exit(response["exit_code"])
