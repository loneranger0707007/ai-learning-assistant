"""Tiny SSH helper for the BA3073 ECS instance (paramiko).

Usage:
    python ecs_ssh.py "<remote command>"
    python ecs_ssh.py --file <local_script_path>
"""
import os
import sys
import paramiko

HOST = "8.163.115.97"
USER = "root"
# Provide the password via the ECS_PASSWORD environment variable; never hardcode it.
PASSWORD = os.environ.get("ECS_PASSWORD", "")


def connect():
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(HOST, username=USER, password=PASSWORD, timeout=20,
                   look_for_keys=False, allow_agent=False)
    return client


def run(client, command, timeout=300):
    stdin, stdout, stderr = client.exec_command(command, timeout=timeout, get_pty=False)
    out = stdout.read().decode("utf-8", errors="replace")
    err = stderr.read().decode("utf-8", errors="replace")
    code = stdout.channel.recv_exit_status()
    return code, out, err


def main():
    client = connect()
    if sys.argv[1] == "--file":
        with open(sys.argv[2], "r", encoding="utf-8") as fh:
            script = fh.read()
        cmd = "bash -s"
        stdin, stdout, stderr = client.exec_command(cmd, timeout=1800)
        stdin.write(script)
        stdin.channel.shutdown_write()
        print(stdout.read().decode("utf-8", errors="replace"))
        e = stderr.read().decode("utf-8", errors="replace")
        if e:
            print("STDERR:", e)
        print("EXIT:", stdout.channel.recv_exit_status())
    else:
        code, out, err = run(client, " ".join(sys.argv[1:]))
        print(out)
        if err:
            print("STDERR:", err)
        print("EXIT:", code)
    client.close()


if __name__ == "__main__":
    main()
