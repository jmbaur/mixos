from argparse import ArgumentParser, REMAINDER
from enum import Enum
import logging
import os
import socket
import varlink


logger = logging.getLogger(__name__)


class Protocol(Enum):
    TCP = 1
    UNIX = 2
    VSOCK = 3
    VSOCK_MUX = 4


class RebootType(Enum):
    reboot = "reboot"
    poweroff = "poweroff"
    kexec = "kexec"

    def __str__(self):
        return self.value


class Machine(varlink.SimpleClientInterfaceHandler):
    def __init__(self, conn, timeout=None):
        """
        Creates a new MixOS Machine

        A timeout, in seconds, bounds how long any single exchange with the
        machine waits on it. Without one, a machine that goes away mid-call
        leaves the caller waiting forever.
        """
        self._conn = Machine._parse_connection_string(conn)
        self._timeout = timeout
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

    def set_timeout(self, timeout):
        """
        Bounds how long each further exchange with the machine waits on it,
        in seconds. None waits forever.
        """
        self._timeout = timeout

        if self._connection is not None:
            self._connection.settimeout(timeout)

    @staticmethod
    def _parse_connection_string(conn: str):
        if conn.startswith("vsock-mux:"):
            split = conn[len("vsock-mux:") :].rsplit(":", maxsplit=1)
            assert len(split) == 2
            path = split[0]
            port = int(split[1])
            return (Protocol.VSOCK_MUX, (path, port))
        elif conn.startswith("vsock:"):
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
                sock.settimeout(self._timeout)
                sock.connect(self._conn[1])
            case Protocol.VSOCK_MUX:
                path, port = self._conn[1]
                logger.debug(f"connecting to vsock multiplexer {path} port {port}")
                sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                sock.settimeout(self._timeout)
                sock.connect(path)
                # Hypervisors that cannot hand out AF_VSOCK to the host
                # (firecracker, cloud-hypervisor, vhost-device-vsock) multiplex
                # it over a unix socket, where a guest port is dialled like
                # this.
                sock.sendall(f"CONNECT {port}\n".encode())
                greeting = b""
                while not greeting.endswith(b"\n"):
                    byte = sock.recv(1)
                    if not byte:
                        raise ConnectionError(
                            f"{path}: the multiplexer closed the connection"
                        )
                    greeting += byte
                if not greeting.startswith(b"OK"):
                    raise ConnectionError(
                        f"{path}: the multiplexer refused port {port}: {greeting!r}"
                    )
            case Protocol.UNIX:
                logger.debug(f"connection to unix domain socket host {self._conn[1]}")
                sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                sock.settimeout(self._timeout)
                sock.connect(self._conn[1])
            case Protocol.TCP:
                logger.debug(f"connecting to TCP host {self._conn[1]}")
                sock = socket.create_connection(self._conn[1], timeout=self._timeout)

        interface_name = "com.jmbaur.mixos"
        client = varlink.Client()
        if interface_name not in client._interfaces:
            client.get_interface(interface_name, socket_connection=sock)

        if interface_name not in client._interfaces:
            raise varlink.InterfaceNotFound(interface_name)

        super().__init__(client._interfaces[interface_name], sock, namespaced=False)


def cli():
    parser = ArgumentParser(prog=__name__)
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
        help="Address of the MixOS machine, of the form <ipv4>:<port>, [<ipv6>]:<port>, vsock:<cid>:<port>, or vsock-mux:<path>:<port>",
    )
    subparsers = parser.add_subparsers(dest="method", help="Varlink method to call")
    parser_run_command = subparsers.add_parser(
        "RunCommand", help="Run a command on a MixOS machine"
    )
    parser_run_command.add_argument(
        "-t", "--timeout", type=int, help="Timeout for command"
    )
    parser_run_command.add_argument(
        "command",
        type=str,
        nargs=REMAINDER,
        help="Command to run",
    )

    parser_reboot = subparsers.add_parser("Reboot", help="Reboot a MixOS machine")
    parser_reboot.add_argument(
        "-t",
        "--reboot-type",
        type=RebootType,
        choices=list(RebootType),
        default="reboot",
        help="The reboot type",
    )

    args = parser.parse_args()

    logging.basicConfig(level=logging.DEBUG if args.debug else logging.INFO)

    match args.method:
        case "RunCommand":
            with Machine(args.address) as machine:
                response = machine.RunCommand(
                    command=args.command, timeout=args.timeout
                )
                print("exit_code:", response["exit_code"])
                print("stdout:\n{}".format(response["stdout"].strip()))
                print("stderr:\n{}".format(response["stderr"].strip()))
        case "Reboot":
            with Machine(args.address) as machine:
                machine.Reboot(reboot_type=str(args.reboot_type))
                print(f'machine rebooted with reboot type "{args.reboot_type}"')
        case _:
            parser.print_usage()
            exit(1)
