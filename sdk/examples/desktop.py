"""Host-application example for the compiled SDK C ABI; contains no SDK engine."""
import argparse
import ctypes as c
import json
import queue
from pathlib import Path
import threading
import tkinter as tk
from tkinter.scrolledtext import ScrolledText


class App:
    def __init__(self, window, library, configuration):
        self.window = window
        self.library = c.CDLL(str(Path(library).resolve()))
        self.handle = c.c_uint64()
        self.callback_type = c.CFUNCTYPE(c.c_int, c.c_char_p, c.c_void_p)
        self.callback = self.callback_type(self.present_consent)
        error_pointer = c.POINTER(c.c_void_p)
        self.library.DoubleDataCreate.argtypes = [c.c_char_p, c.POINTER(c.c_uint64), error_pointer]
        self.library.DoubleDataRequestConsent.argtypes = [c.c_uint64, self.callback_type, c.c_void_p, error_pointer]
        for name in ("Start", "Stop", "WithdrawConsent", "Destroy"):
            getattr(self.library, "DoubleData" + name).argtypes = [c.c_uint64, error_pointer]
        self.library.DoubleDataStatus.argtypes = [c.c_uint64, c.POINTER(c.c_void_p), error_pointer]
        self.library.DoubleDataFreeString.argtypes = [c.c_void_p]
        self.library.DoubleDataFreeString.restype = None
        config = Path(configuration).read_bytes()
        self.check(self.library.DoubleDataCreate, config, c.byref(self.handle))
        self.status = tk.StringVar(value="Sharing is off. Consent is required.")
        self.events = queue.SimpleQueue()
        self.polling = False
        self.busy = False
        tk.Label(window, textvariable=self.status, wraplength=560, justify="left").pack(padx=20, pady=20)
        self.buttons = [
            tk.Button(window, text="Review consent and enable sharing", command=self.enable),
            tk.Button(window, text="Pause sharing", command=lambda: self.background("Stop")),
            tk.Button(window, text="Withdraw consent", command=lambda: self.background("WithdrawConsent")),
        ]
        for button in self.buttons:
            button.pack(padx=20, pady=5)
        window.protocol("WM_DELETE_WINDOW", self.close)
        self.closed = False
        window.after(500, self.refresh)

    def check(self, function, *args):
        error = c.c_void_p()
        result = function(*args, c.byref(error))
        detail = c.string_at(error).decode() if error.value else "SDK operation failed"
        if error.value:
            self.library.DoubleDataFreeString(error)
        if result:
            raise RuntimeError(detail)

    def present_consent(self, raw, _context):
        try:
            notice = json.loads(raw.decode())
            text = (f"Operator: {notice['controller']}\nContact: {notice['contact']}\n"
                    f"Purpose: {notice['purpose']}\nPrivacy: {notice['privacy_url']}\n"
                    f"Notice version: {notice['version']}\n\n"
                    f"{notice['text']}\n\nThird-party requests use your connection and public IP. "
                    "This uses bandwidth and power and may affect IP reputation. "
                    "Enable only if you are an adult authorised to use this device and connection. "
                    "You can decline or withdraw at any time.\n\nEnable proxy participation?")
            dialog = tk.Toplevel(self.window)
            dialog.title("Optional proxy participation")
            dialog.transient(self.window)
            accepted = tk.BooleanVar(value=False)
            def decide(value):
                accepted.set(value)
                dialog.destroy()
            content = ScrolledText(dialog, wrap="word", width=76, height=20)
            content.insert("1.0", text)
            content.configure(state="disabled")
            content.pack(padx=16, pady=16, fill="both", expand=True)
            controls = tk.Frame(dialog)
            controls.pack(padx=16, pady=16)
            tk.Button(controls, text="Enable sharing", command=lambda: decide(True)).pack(side="left", padx=12)
            refuse = tk.Button(controls, text="No thanks", command=lambda: decide(False))
            refuse.pack(side="left", padx=12)
            refuse.focus_set()
            dialog.protocol("WM_DELETE_WINDOW", lambda: decide(False))
            dialog.bind("<Escape>", lambda _event: decide(False))
            dialog.grab_set()
            self.window.wait_window(dialog)
            return 1 if accepted.get() else 0
        except Exception:
            return -1

    def enable(self):
        try:
            self.check(self.library.DoubleDataRequestConsent, self.handle, self.callback, None)
            self.check(self.library.DoubleDataStart, self.handle)
        except RuntimeError as error:
            self.status.set(str(error))

    def background(self, operation):
        if self.busy or self.closed:
            return
        self.busy = True
        for button in self.buttons:
            button.configure(state="disabled")
        def execute():
            try:
                self.check(getattr(self.library, "DoubleData" + operation), self.handle)
            except RuntimeError as error:
                self.events.put(("error", str(error)))
            finally:
                self.events.put(("operation_done", None))
        threading.Thread(target=execute, daemon=True).start()

    def refresh(self):
        if self.closed:
            return
        while not self.events.empty():
            kind, value = self.events.get()
            if kind == "error":
                self.status.set(value)
            elif kind == "operation_done":
                self.busy = False
                for button in self.buttons:
                    button.configure(state="normal")
            elif kind == "status":
                self.polling = False
                self.status.set(f"Sharing: {value['state']} | consent: {value['consent_state']}\n"
                                f"Payload bytes: {value['bytes_used']} / {value['byte_limit']}")
        if not self.polling:
            self.polling = True
            threading.Thread(target=self.read_status, daemon=True).start()
        self.window.after(500, self.refresh)

    def read_status(self):
        raw, error = c.c_void_p(), c.c_void_p()
        result = self.library.DoubleDataStatus(self.handle, c.byref(raw), c.byref(error))
        if raw.value:
            state = json.loads(c.string_at(raw).decode())
            self.library.DoubleDataFreeString(raw)
            self.events.put(("status", state))
        if error.value:
            self.events.put(("error", c.string_at(error).decode()))
            self.library.DoubleDataFreeString(error)
        if result:
            self.events.put(("operation_done", None))

    def close(self):
        self.closed = True
        self.status.set("Stopping SDK and closing connections…")
        def destroy():
            try:
                self.check(self.library.DoubleDataDestroy, self.handle)
            except RuntimeError as error:
                detail = str(error)
                self.window.after(0, lambda: self.status.set(detail))
                self.closed = False
                return
            self.window.after(0, self.window.destroy)
        threading.Thread(target=destroy, daemon=True).start()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--library", required=True)
    parser.add_argument("--config", required=True)
    args = parser.parse_args()
    window = tk.Tk()
    window.title("DoubleData proxy participation")
    App(window, args.library, args.config)
    window.mainloop()
