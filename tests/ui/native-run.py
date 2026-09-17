"""Run the native QML fixture and require a clean exit."""

import subprocess
import sys
import time


def run(harness, log):
    with open(log, "w") as output:
        process = subprocess.Popen(["quickshell", "-p", harness, "--no-color"],
                                   stdout=output, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 30
            while process.poll() is None:
                if time.monotonic() >= deadline:
                    raise RuntimeError("Native fixture did not exit")
                time.sleep(0.05)
            if process.returncode != 0:
                raise RuntimeError(f"Native fixture failed: {process.returncode}")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)


if __name__ == "__main__":
    run(sys.argv[1], sys.argv[2])
