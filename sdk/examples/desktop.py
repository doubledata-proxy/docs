"""Host-application example for the compiled SDK C ABI; contains no SDK engine."""
import argparse
import ctypes as c
import json
import queue
from pathlib import Path
import threading
import tkinter as tk
from tkinter import ttk
from tkinter.scrolledtext import ScrolledText
import webbrowser


def present_consent(window, notice):
    """Style this host-owned screen, or pass your own callback to App.

    Display the full configured notice and return True only after an explicit
    Enable sharing choice. Decline, Escape, and closing the dialog return False.
    The receipt version stays in SDK metadata; it is not participation copy.
    """
    title = notice.get("title") or "Share your connection"
    dialog = tk.Toplevel(window)
    dialog.title(title)
    dialog.transient(window)
    dialog.geometry("720x640")
    dialog.minsize(480, 440)
    accepted = False

    def decide(value=False):
        nonlocal accepted
        accepted = value is True
        dialog.destroy()

    try:
        body = ttk.Frame(dialog, padding=24)
        body.pack(fill="both", expand=True)
        body.columnconfigure(0, weight=1)
        body.rowconfigure(1, weight=1)
        heading = ttk.Label(body, text=title, font=("Segoe UI", 20, "bold"), wraplength=660)
        heading.grid(row=0, column=0, sticky="ew", pady=(0, 12))
        content = ScrolledText(body, wrap="word", width=70, height=12,
                               font=("Segoe UI", 11), padx=12, pady=12,
                               relief="flat", borderwidth=0, highlightthickness=1)
        content.tag_configure("purpose", font=("Segoe UI", 11, "bold"))
        content.tag_configure("privacy", foreground="#205cb2", underline=True)
        content.insert("end", notice["purpose"] + "\n\n", "purpose")
        content.insert("end", notice["text"] + "\n\n")
        content.insert("end", f"Provided by: {notice['controller']}\nContact: {notice['contact']}\n")
        content.insert("end", notice["privacy_url"], "privacy")
        content.tag_bind("privacy", "<Button-1>", lambda _event: webbrowser.open(notice["privacy_url"]))
        content.tag_bind("privacy", "<Enter>", lambda _event: content.configure(cursor="hand2"))
        content.tag_bind("privacy", "<Leave>", lambda _event: content.configure(cursor="xterm"))
        content.configure(state="disabled")
        content.grid(row=1, column=0, sticky="nsew")
        controls = ttk.Frame(body)
        controls.grid(row=2, column=0, sticky="ew", pady=(20, 0))
        ttk.Button(controls, text="Privacy policy", command=lambda: webbrowser.open(notice["privacy_url"])).pack(side="left")
        decisions = ttk.Frame(controls)
        decisions.pack(side="right")
        decline = ttk.Button(decisions, text="Decline", command=decide)
        decline.pack(side="left", padx=(0, 12))
        ttk.Button(decisions, text="Enable sharing", command=lambda: decide(True)).pack(side="left")

        def resize(event):
            heading.configure(wraplength=max(1, event.width - 48))

        body.bind("<Configure>", resize)
        dialog.protocol("WM_DELETE_WINDOW", decide)
        dialog.bind("<Escape>", lambda _event: decide())
        dialog.wait_visibility()
        dialog.grab_set()
        decline.focus_set()
        window.wait_window(dialog)
        return accepted
    finally:
        if dialog.winfo_exists():
            dialog.destroy()


def sharing_status(status):
    """Translate SDK metadata into copy for the person using the host app."""
    consent = status.get("consent_state")
    if consent == "withdrawn":
        return "Sharing is off. You withdrew permission."
    if consent == "expired":
        return "Sharing is off. Review the notice to enable it again."
    if consent == "awaiting_consent":
        return "Review the notice to choose whether to share."
    if consent != "granted":
        return "Sharing is off. You can enable it whenever you choose."
    return {
        "starting": "Connecting to enable sharing…",
        "registering": "Connecting to enable sharing…",
        "connecting": "Connecting to enable sharing…",
        "running": "Sharing is on. You can pause or withdraw at any time.",
        "retrying": "Reconnecting… You can pause or withdraw at any time.",
        "stopping": "Pausing sharing…",
        "failed": "Sharing stopped. Please try again.",
    }.get(status.get("state"), "Sharing is paused. Enable sharing when you are ready.")


class App:
    def __init__(self, window, library, configuration, present_consent=present_consent):
        self.window = window
        self.present_consent = present_consent
        self.library = c.CDLL(str(Path(library).resolve()))
        self.handle = c.c_uint64()
        self.callback_type = c.CFUNCTYPE(c.c_int, c.c_char_p, c.c_void_p)
        self.callback = self.callback_type(self._consent_callback)
        error_pointer = c.POINTER(c.c_void_p)
        self.library.DoubleDataCreate.argtypes = [c.c_char_p, c.POINTER(c.c_uint64), error_pointer]
        self.library.DoubleDataRequestConsent.argtypes = [c.c_uint64, self.callback_type, c.c_void_p, error_pointer]
        for name in ("Start", "Stop", "InvalidateConsent", "WithdrawConsent", "Destroy"):
            getattr(self.library, "DoubleData" + name).argtypes = [c.c_uint64, error_pointer]
        self.library.DoubleDataStatus.argtypes = [c.c_uint64, c.POINTER(c.c_void_p), error_pointer]
        self.library.DoubleDataFreeString.argtypes = [c.c_void_p]
        self.library.DoubleDataFreeString.restype = None
        config = Path(configuration).read_bytes()
        self.check(self.library.DoubleDataCreate, config, c.byref(self.handle))
        self.status = tk.StringVar(value="Sharing is off. You choose when to enable it.")
        self.events = queue.SimpleQueue()
        self.polling = False
        self.busy = False
        self.cleanup_pending = False
        window.minsize(520, 300)
        body = ttk.Frame(window, padding=24)
        body.pack(fill="both", expand=True)
        ttk.Label(body, text="Connection sharing", font=("Segoe UI", 20, "bold")).pack(anchor="w", pady=(0, 12))
        ttk.Label(body, textvariable=self.status, wraplength=560, justify="left").pack(anchor="w", pady=(0, 24))
        controls = ttk.Frame(body)
        controls.pack(anchor="w")
        self.buttons = [
            ttk.Button(controls, text="Enable sharing", command=self.enable),
            ttk.Button(controls, text="Pause sharing", command=lambda: self.background("Stop")),
            ttk.Button(controls, text="Withdraw consent", command=lambda: self.background("WithdrawConsent")),
        ]
        for button in self.buttons:
            button.pack(side="left", padx=(0, 12))
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

    def _consent_callback(self, raw, _context):
        try:
            notice = json.loads(raw.decode())
            accepted = self.present_consent(self.window, notice)
            if accepted is True:
                return 1
            return 0 if accepted is False else -1
        except Exception:
            return -1

    def enable(self):
        if self.busy or self.closed or self.cleanup_pending:
            return
        self.busy = True
        self.update_buttons()
        try:
            self.check(self.library.DoubleDataRequestConsent, self.handle, self.callback, None)
        except RuntimeError as error:
            if not self.closed:
                if str(error) == "user declined or dismissed contribution":
                    self.status.set("Sharing is off. You can enable it whenever you choose.")
                else:
                    self.status.set(f"Sharing couldn't start: {error}")
            return
        finally:
            self.busy = False
            self.update_buttons()
        if not self.closed:
            self.background("Start")

    def update_buttons(self):
        for button in self.buttons:
            button.configure(state="disabled" if self.busy or self.closed or self.cleanup_pending else "normal")

    def background(self, operation):
        if self.busy or self.closed or self.cleanup_pending:
            return
        if operation == "WithdrawConsent":
            self.check(self.library.DoubleDataInvalidateConsent, self.handle)
        self.busy = True
        self.update_buttons()
        self.status.set({"Start": "Connecting to enable sharing…", "Stop": "Pausing sharing…",
                         "WithdrawConsent": "Turning sharing off…"}[operation])
        def execute():
            try:
                self.check(getattr(self.library, "DoubleData" + operation), self.handle)
            except RuntimeError as error:
                self.events.put(("error", str(error)))
            finally:
                self.events.put(("operation_done", None))
        threading.Thread(target=execute, daemon=True).start()

    def refresh(self):
        while not self.events.empty():
            kind, value = self.events.get()
            if kind == "destroyed":
                self.window.destroy()
                return
            if kind == "close_failed":
                self.closed = False
                self.busy = False
                self.status.set(f"Sharing is off. Close the window again to retry cleanup: {value}")
                # The native handle is retained for another Destroy attempt.
                # Keep other actions disabled while cleanup is incomplete.
                continue
            if kind == "status_done":
                self.polling = False
            elif not self.closed and not self.cleanup_pending:
                if kind == "error":
                    self.status.set(f"Couldn't update sharing: {value}")
                elif kind == "operation_done":
                    self.busy = False
                    self.update_buttons()
                elif kind == "status" and not self.busy:
                    self.status.set(sharing_status(value))
        if not self.closed and not self.cleanup_pending and not self.polling:
            self.polling = True
            threading.Thread(target=self.read_status, daemon=True).start()
        self.window.after(100 if self.closed else 500, self.refresh)

    def read_status(self):
        raw, error = c.c_void_p(), c.c_void_p()
        try:
            result = self.library.DoubleDataStatus(self.handle, c.byref(raw), c.byref(error))
            if result:
                detail = c.string_at(error).decode() if error.value else "Sharing status is unavailable"
                raise RuntimeError(detail)
            if raw.value:
                self.events.put(("status", json.loads(c.string_at(raw).decode())))
        except (RuntimeError, ValueError, UnicodeError) as detail:
            self.events.put(("error", str(detail)))
        finally:
            if raw.value:
                self.library.DoubleDataFreeString(raw)
            if error.value:
                self.library.DoubleDataFreeString(error)
            self.events.put(("status_done", None))

    def close(self):
        if self.closed:
            return
        self.closed = True
        self.cleanup_pending = True
        self.update_buttons()
        self.status.set("Turning sharing off and closing…")
        try:
            self.check(self.library.DoubleDataInvalidateConsent, self.handle)
        except RuntimeError as error:
            self.events.put(("error", str(error)))
        for child in self.window.winfo_children():
            if isinstance(child, tk.Toplevel):
                child.destroy()
        def destroy():
            try:
                self.check(self.library.DoubleDataDestroy, self.handle)
            except RuntimeError as error:
                self.events.put(("close_failed", str(error)))
                return
            self.events.put(("destroyed", None))
        threading.Thread(target=destroy, daemon=True).start()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--library", required=True)
    parser.add_argument("--config", required=True)
    args = parser.parse_args()
    window = tk.Tk()
    window.title("Connection sharing")
    App(window, args.library, args.config)
    window.mainloop()
