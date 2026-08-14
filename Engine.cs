// Text Shortcuts engine: a system-wide, low-level keyboard-hook text expander.
// Shared by TextShortcuts.ps1 (headless) and TextShortcutsManager.ps1 (GUI).
//
// Long / multi-line expansions are delivered via the clipboard (Ctrl+V) which is
// instant and reliable; short single-line ones are typed as keystrokes. The previous
// clipboard contents are saved and restored shortly after (see Tick()).
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace TextShortcuts {
  public static class Engine {
    const int  WH_KEYBOARD_LL = 13;
    const int  WM_KEYDOWN = 0x0100, WM_SYSKEYDOWN = 0x0104;
    const uint LLKHF_INJECTED = 0x10;
    const int  VK_BACK = 0x08, VK_TAB = 0x09, VK_RETURN = 0x0D, VK_SHIFT = 0x10, VK_CONTROL = 0x11, VK_MENU = 0x12, VK_V = 0x56;
    const uint KEYEVENTF_KEYUP = 0x0002, KEYEVENTF_UNICODE = 0x0004;
    const uint INPUT_KEYBOARD = 1, PM_REMOVE = 0x0001;
    const uint CF_UNICODETEXT = 13, GMEM_MOVEABLE = 0x0002;

    [StructLayout(LayoutKind.Sequential)]
    struct KBDLLHOOKSTRUCT { public uint vkCode; public uint scanCode; public uint flags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    struct HARDWAREINPUT { public uint uMsg; public ushort wParamL; public ushort wParamH; }
    [StructLayout(LayoutKind.Explicit)]
    struct InputUnion { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; [FieldOffset(0)] public HARDWAREINPUT hi; }
    [StructLayout(LayoutKind.Sequential)]
    struct INPUT { public uint type; public InputUnion U; }
    [StructLayout(LayoutKind.Sequential)]
    struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public int pt_x; public int pt_y; }

    delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError=true)] static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);
    [DllImport("user32.dll", SetLastError=true)] static extern bool UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr GetModuleHandle(string lpModuleName);
    [DllImport("user32.dll")] static extern bool GetKeyboardState(byte[] lpKeyState);
    [DllImport("user32.dll")] static extern int ToUnicode(uint wVirtKey, uint wScanCode, byte[] lpKeyState, StringBuilder pwszBuff, int cchBuff, uint wFlags);
    [DllImport("user32.dll")] static extern short GetKeyState(int nVirtKey);
    [DllImport("user32.dll", SetLastError=true)] static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
    [DllImport("user32.dll")] static extern bool PeekMessage(out MSG lpMsg, IntPtr hWnd, uint min, uint max, uint remove);
    [DllImport("user32.dll")] static extern bool TranslateMessage(ref MSG lpMsg);
    [DllImport("user32.dll")] static extern IntPtr DispatchMessage(ref MSG lpMsg);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")] static extern bool OpenClipboard(IntPtr hWndNewOwner);
    [DllImport("user32.dll")] static extern bool CloseClipboard();
    [DllImport("user32.dll")] static extern bool EmptyClipboard();
    [DllImport("user32.dll")] static extern IntPtr GetClipboardData(uint uFormat);
    [DllImport("user32.dll")] static extern IntPtr SetClipboardData(uint uFormat, IntPtr hMem);
    [DllImport("user32.dll")] static extern bool IsClipboardFormatAvailable(uint format);
    [DllImport("kernel32.dll")] static extern IntPtr GlobalAlloc(uint uFlags, UIntPtr dwBytes);
    [DllImport("kernel32.dll")] static extern IntPtr GlobalLock(IntPtr hMem);
    [DllImport("kernel32.dll")] static extern bool GlobalUnlock(IntPtr hMem);
    [DllImport("kernel32.dll")] static extern IntPtr GlobalFree(IntPtr hMem);

    static IntPtr _hook = IntPtr.Zero;
    static readonly LowLevelKeyboardProc _proc = HookCallback;   // held to prevent GC
    static readonly StringBuilder _word = new StringBuilder();   // current word since last boundary
    static Dictionary<string,string> _map = new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
    static bool _instant = true;
    static bool _enabled = true;
    static int  _pasteMode = 1;                                  // 0 = never, 1 = auto (long/multiline), 2 = always
    static IntPtr _ownWindow = IntPtr.Zero;                      // expansion is suppressed while this window is focused

    // deferred clipboard restore
    static bool   _restorePending = false;
    static int    _restoreAt = 0;
    static string _savedClip = null;

    public static long Count = 0;
    public static bool Installed { get { return _hook != IntPtr.Zero; } }
    public static int  InputSize { get { return Marshal.SizeOf(typeof(INPUT)); } }

    public static void SetEnabled(bool enabled) { _enabled = enabled; _word.Length = 0; }
    public static void SetOwnWindow(IntPtr hwnd) { _ownWindow = hwnd; }

    public static void Load(string[] keys, string[] values, bool instant, bool matchCase, int pasteMode) {
      _instant = instant;
      _pasteMode = pasteMode;
      var map = new Dictionary<string,string>(matchCase ? StringComparer.Ordinal : StringComparer.OrdinalIgnoreCase);
      for (int i = 0; i < keys.Length; i++) map[keys[i]] = values[i];
      _map = map;
      _word.Length = 0;
    }

    public static void Install(string[] keys, string[] values, bool instant, bool matchCase, int pasteMode) {
      Load(keys, values, instant, matchCase, pasteMode);
      if (_hook == IntPtr.Zero) {
        _hook = SetWindowsHookEx(WH_KEYBOARD_LL, _proc, GetModuleHandle(null), 0);
        if (_hook == IntPtr.Zero) throw new Exception("SetWindowsHookEx failed (" + Marshal.GetLastWin32Error() + ").");
      }
    }
    public static void Uninstall() { if (_hook != IntPtr.Zero) { UnhookWindowsHookEx(_hook); _hook = IntPtr.Zero; } }

    public static void Pump() {
      MSG m;
      while (PeekMessage(out m, IntPtr.Zero, 0, 0, PM_REMOVE)) { TranslateMessage(ref m); DispatchMessage(ref m); }
    }

    // Call periodically from the host (GUI timer / headless loop) to restore the clipboard after a paste-expansion.
    public static void Tick() {
      if (_restorePending && (Environment.TickCount - _restoreAt) >= 0) {
        _restorePending = false;
        if (_savedClip != null) { try { SetClipboardText(_savedClip); } catch { } }
        _savedClip = null;
      }
    }

    // Test helper: feed a string as if typed ('\b' = backspace). Returns last expansion produced, or null. Sends nothing.
    public static string Probe(string typed) {
      _word.Length = 0; string last = null;
      foreach (char ch in typed) {
        if (ch == '\b') { if (_word.Length > 0) _word.Remove(_word.Length - 1, 1); continue; }
        if (IsWordChar(ch)) {
          _word.Append(ch);
          if (_instant) { string e; if (_map.TryGetValue(_word.ToString(), out e)) { last = Expand(e); _word.Length = 0; } }
        } else {
          if (!_instant && _word.Length > 0) { string e; if (_map.TryGetValue(_word.ToString(), out e)) last = Expand(e); }
          _word.Length = 0;
        }
      }
      return last;
    }

    static bool IsWordChar(char c) { return char.IsLetterOrDigit(c); }

    static IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam) {
      if (nCode >= 0) {
        int msg = wParam.ToInt32();
        if (msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN) {
          KBDLLHOOKSTRUCT k = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(KBDLLHOOKSTRUCT));
          if ((k.flags & LLKHF_INJECTED) == 0) {
            try { if (Process(k.vkCode, k.scanCode)) return (IntPtr)1; } catch { }
          }
        }
      }
      return CallNextHookEx(_hook, nCode, wParam, lParam);
    }

    static bool Process(uint vk, uint scan) {
      if (!_enabled) return false;
      if (_ownWindow != IntPtr.Zero && GetForegroundWindow() == _ownWindow) { _word.Length = 0; return false; }

      if (vk == VK_BACK) { if (_word.Length > 0) _word.Remove(_word.Length - 1, 1); return false; }
      bool ctrl = (GetKeyState(VK_CONTROL) & 0x8000) != 0;
      bool alt  = (GetKeyState(VK_MENU)    & 0x8000) != 0;
      if (ctrl || alt) { _word.Length = 0; return false; }

      byte[] state = new byte[256];
      GetKeyboardState(state);
      StringBuilder sb = new StringBuilder(8);
      int rc = ToUnicode(vk, scan, state, sb, sb.Capacity, 0);
      if (rc <= 0 || sb.Length == 0) { _word.Length = 0; return false; }   // function keys, dead keys -> boundary
      char c = sb[sb.Length - 1];

      if (IsWordChar(c)) {
        _word.Append(c);
        if (_word.Length > 64) _word.Remove(0, _word.Length - 64);
        if (_instant) {
          string exp;
          if (_map.TryGetValue(_word.ToString(), out exp)) {
            int back = _word.Length - 1;   // current (blocking) key was never delivered
            string text = Expand(exp);
            _word.Length = 0; Count++;
            Deliver(back, text);
            return true;
          }
        }
        return false;
      }
      else {
        if (!_instant && _word.Length > 0) {
          string exp;
          if (_map.TryGetValue(_word.ToString(), out exp)) {
            int back = _word.Length;
            string text = Expand(exp);
            _word.Length = 0; Count++;
            SendExpansionEnding(back, text, c, vk);
            return true;
          }
        }
        _word.Length = 0;
        return false;
      }
    }

    static string Expand(string t) {
      if (t.IndexOf('{') < 0) return t;
      DateTime n = DateTime.Now;
      t = t.Replace("{date}", n.ToShortDateString());
      t = t.Replace("{time}", n.ToShortTimeString());
      t = t.Replace("{datetime}", n.ToString());
      t = t.Replace("{enter}", "\n");   // line break (AddText/clipboard turn \n into Enter)
      t = t.Replace("{tab}", "\t");
      return t;
    }

    static bool ShouldPaste(string text) {
      if (_pasteMode == 0) return false;
      // A tab must reach the app as a real VK_TAB key press so it acts as TAB (field/control
      // navigation). Pasted via the clipboard it would arrive as a literal tab CHARACTER and
      // never navigate, so any expansion containing {tab} is always delivered as keystrokes.
      if (text.IndexOf('\t') >= 0) return false;
      if (_pasteMode == 2) return true;
      return text.Length >= 12 || text.IndexOf('\n') >= 0;   // auto
    }

    // Ending-char mode: whole abbreviation delivered; ending char blocked and re-emitted after.
    static void SendExpansionEnding(int back, string text, char endChar, uint endVk) {
      if (ShouldPaste(text)) {
        if (PasteExpansion(back, text, true, endChar, endVk)) return;
      }
      var list = new List<INPUT>();
      AddBackspaces(list, back);
      AddText(list, text);
      AddEndChar(list, endChar, endVk);
      Flush(list);
    }

    static void Deliver(int back, string text) {
      if (ShouldPaste(text)) {
        if (PasteExpansion(back, text, false, '\0', 0)) return;
      }
      var list = new List<INPUT>();
      AddBackspaces(list, back);
      AddText(list, text);
      Flush(list);
    }

    // Returns false if clipboard couldn't be used (caller falls back to keystrokes).
    static bool PasteExpansion(int back, string text, bool withEnd, char endChar, uint endVk) {
      string saved = null;
      try { saved = GetClipboardText(); } catch { saved = null; }
      if (!SetClipboardText(text)) return false;
      _savedClip = saved;
      _restorePending = true;
      _restoreAt = Environment.TickCount + 800;   // restore the user's clipboard ~800ms after paste
                                                  // (long enough for slow web/rich editors to finish the paste)

      var list = new List<INPUT>();
      AddBackspaces(list, back);
      // Ctrl+V
      list.Add(Key(VK_CONTROL, false));
      list.Add(Key(VK_V, false));
      list.Add(Key(VK_V, true));
      list.Add(Key(VK_CONTROL, true));
      if (withEnd) AddEndChar(list, endChar, endVk);
      Flush(list);
      return true;
    }

    static void AddBackspaces(List<INPUT> list, int n) {
      for (int i = 0; i < n; i++) { list.Add(Key(VK_BACK, false)); list.Add(Key(VK_BACK, true)); }
    }
    static void AddText(List<INPUT> list, string text) {
      foreach (char c in text) {
        // Line breaks are sent as Shift+Enter so they don't submit forms/chat/ticket boxes
        // (where a plain Enter means "send"). Renders as a normal line break everywhere else.
        if (c == '\n')      { list.Add(Key(VK_SHIFT, false)); list.Add(Key(VK_RETURN, false)); list.Add(Key(VK_RETURN, true)); list.Add(Key(VK_SHIFT, true)); }
        else if (c == '\r') { }
        else if (c == '\t') { list.Add(Key(VK_TAB, false));    list.Add(Key(VK_TAB, true)); }
        else                { list.Add(Uni(c, false));         list.Add(Uni(c, true)); }
      }
    }
    static void AddEndChar(List<INPUT> list, char c, uint vk) {
      if (vk == VK_RETURN || c == '\r' || c == '\n') { list.Add(Key(VK_RETURN, false)); list.Add(Key(VK_RETURN, true)); }
      else if (vk == VK_TAB || c == '\t')            { list.Add(Key(VK_TAB, false));    list.Add(Key(VK_TAB, true)); }
      else                                           { list.Add(Uni(c, false));         list.Add(Uni(c, true)); }
    }
    static void Flush(List<INPUT> list) {
      if (list.Count > 0) SendInput((uint)list.Count, list.ToArray(), Marshal.SizeOf(typeof(INPUT)));
    }

    static INPUT Key(int vk, bool up) { INPUT i = new INPUT(); i.type = INPUT_KEYBOARD; i.U.ki.wVk = (ushort)vk; i.U.ki.dwFlags = up ? KEYEVENTF_KEYUP : 0; return i; }
    static INPUT Uni(char c, bool up) { INPUT i = new INPUT(); i.type = INPUT_KEYBOARD; i.U.ki.wScan = (ushort)c; i.U.ki.dwFlags = KEYEVENTF_UNICODE | (up ? KEYEVENTF_KEYUP : 0); return i; }

    // ---- clipboard helpers (Win32, work from any apartment) ----
    static bool TryOpenClipboard() {
      for (int i = 0; i < 8; i++) { if (OpenClipboard(IntPtr.Zero)) return true; }
      return false;
    }
    static string GetClipboardText() {
      if (!IsClipboardFormatAvailable(CF_UNICODETEXT)) return null;
      if (!TryOpenClipboard()) return null;
      try {
        IntPtr h = GetClipboardData(CF_UNICODETEXT);
        if (h == IntPtr.Zero) return null;
        IntPtr p = GlobalLock(h);
        if (p == IntPtr.Zero) return null;
        try { return Marshal.PtrToStringUni(p); } finally { GlobalUnlock(h); }
      } finally { CloseClipboard(); }
    }
    static bool SetClipboardText(string s) {
      if (s == null) s = "";
      if (!TryOpenClipboard()) return false;
      try {
        EmptyClipboard();
        byte[] bytes = Encoding.Unicode.GetBytes(s + "\0");
        IntPtr hMem = GlobalAlloc(GMEM_MOVEABLE, (UIntPtr)bytes.Length);
        if (hMem == IntPtr.Zero) return false;
        IntPtr p = GlobalLock(hMem);
        if (p == IntPtr.Zero) { GlobalFree(hMem); return false; }
        Marshal.Copy(bytes, 0, p, bytes.Length);
        GlobalUnlock(hMem);
        if (SetClipboardData(CF_UNICODETEXT, hMem) == IntPtr.Zero) { GlobalFree(hMem); return false; }
        return true;   // system owns hMem now
      } finally { CloseClipboard(); }
    }
  }
}
