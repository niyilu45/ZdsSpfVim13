#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0600
#endif

#include <windows.h>
#include <tlhelp32.h>
#include <stdlib.h>
#include <wchar.h>

#define INJECTED_MARKER ((ULONG_PTR)0x5350463133434150ULL)

static DWORD target_process_id;
static DWORD window_search_process_id;
static HANDLE target_process;
static HWND initial_foreground_window;
static HWND target_window;
static HHOOK keyboard_hook;
static BOOL captured_caps;
static BOOL injected_ctrl;
static BOOL target_is_gui_vim;

static BOOL target_is_vim(void)
{
    WCHAR image_path[32768];
    DWORD image_path_length = (DWORD)(sizeof(image_path) / sizeof(image_path[0]));
    const WCHAR *file_name;

    if (!QueryFullProcessImageNameW(target_process, 0, image_path,
                                    &image_path_length)) {
        return FALSE;
    }

    file_name = wcsrchr(image_path, L'\\');
    file_name = file_name == NULL ? image_path : file_name + 1;
    target_is_gui_vim = _wcsicmp(file_name, L"gvim.exe") == 0;
    return _wcsicmp(file_name, L"vim.exe") == 0 || target_is_gui_vim;
}

static BOOL CALLBACK find_target_window(HWND window, LPARAM unused)
{
    DWORD process_id = 0;
    (void)unused;

    GetWindowThreadProcessId(window, &process_id);
    if (process_id == window_search_process_id && IsWindowVisible(window)) {
        target_window = window;
        return FALSE;
    }
    return TRUE;
}

static DWORD get_parent_process_id(DWORD process_id)
{
    HANDLE snapshot;
    PROCESSENTRY32W entry;
    DWORD parent_process_id = 0;

    snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) {
        return 0;
    }

    ZeroMemory(&entry, sizeof(entry));
    entry.dwSize = sizeof(entry);
    if (Process32FirstW(snapshot, &entry)) {
        do {
            if (entry.th32ProcessID == process_id) {
                parent_process_id = entry.th32ParentProcessID;
                break;
            }
        } while (Process32NextW(snapshot, &entry));
    }

    CloseHandle(snapshot);
    return parent_process_id;
}

static void find_target_or_terminal_window(void)
{
    DWORD process_id = target_process_id;
    DWORD parent_process_id;
    unsigned int depth;

    target_window = NULL;
    for (depth = 0; depth < 16 && process_id != 0; ++depth) {
        window_search_process_id = process_id;
        EnumWindows(find_target_window, 0);
        if (target_window != NULL) {
            return;
        }

        /* gVim owns its window.  Do not accidentally bind to an Explorer
           ancestor while its GUI is still being created. */
        if (target_is_gui_vim) {
            return;
        }

        parent_process_id = get_parent_process_id(process_id);
        if (parent_process_id == 0 || parent_process_id == process_id) {
            break;
        }
        process_id = parent_process_id;
    }
}

static BOOL target_is_foreground(void)
{
    HWND foreground = GetForegroundWindow();
    DWORD process_id = 0;

    if (foreground == NULL) {
        return FALSE;
    }

    GetWindowThreadProcessId(foreground, &process_id);
    if (process_id == target_process_id) {
        return TRUE;
    }

    if (target_window == NULL || !IsWindow(target_window)) {
        find_target_or_terminal_window();
    }

    if (target_window != NULL) {
        return foreground == target_window;
    }

    if (target_is_gui_vim) {
        return FALSE;
    }

    /* Console Vim is hosted by a terminal process.  Remember the terminal
       window that was active when Vim started the helper. */
    return foreground == initial_foreground_window;
}

static void send_left_ctrl(BOOL key_down)
{
    INPUT input;
    ZeroMemory(&input, sizeof(input));
    input.type = INPUT_KEYBOARD;
    input.ki.wVk = VK_LCONTROL;
    input.ki.dwFlags = key_down ? 0 : KEYEVENTF_KEYUP;
    input.ki.dwExtraInfo = INJECTED_MARKER;
    SendInput(1, &input, sizeof(input));
    injected_ctrl = key_down;
}

static void release_ctrl(void)
{
    if (injected_ctrl) {
        send_left_ctrl(FALSE);
    }
}

static LRESULT CALLBACK keyboard_proc(int code, WPARAM message, LPARAM data)
{
    const KBDLLHOOKSTRUCT *key = (const KBDLLHOOKSTRUCT *)data;
    BOOL key_down;
    BOOL key_up;

    if (code != HC_ACTION || key->vkCode != VK_CAPITAL ||
        key->dwExtraInfo == INJECTED_MARKER) {
        return CallNextHookEx(keyboard_hook, code, message, data);
    }

    key_down = message == WM_KEYDOWN || message == WM_SYSKEYDOWN;
    key_up = message == WM_KEYUP || message == WM_SYSKEYUP;

    if (key_down && target_is_foreground()) {
        captured_caps = TRUE;
        if (!injected_ctrl) {
            send_left_ctrl(TRUE);
        }
        return 1;
    }

    if (key_up && captured_caps) {
        release_ctrl();
        captured_caps = FALSE;
        return 1;
    }

    if (captured_caps) {
        return 1;
    }

    return CallNextHookEx(keyboard_hook, code, message, data);
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE previous, LPWSTR command_line,
                    int show_command)
{
    WCHAR mutex_name[80];
    HANDLE mutex;
    MSG message;
    DWORD wait_result;

    (void)previous;
    (void)show_command;

    target_process_id = (DWORD)_wtoi(command_line);
    if (target_process_id == 0) {
        return 2;
    }

    wsprintfW(mutex_name, L"Local\\spf13-capsctrl-%lu",
              (unsigned long)target_process_id);
    mutex = CreateMutexW(NULL, TRUE, mutex_name);
    if (mutex == NULL) {
        return 3;
    }
    if (GetLastError() == ERROR_ALREADY_EXISTS) {
        CloseHandle(mutex);
        return 0;
    }

    target_process = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION,
                                 FALSE, target_process_id);
    if (target_process == NULL) {
        CloseHandle(mutex);
        return 4;
    }
    if (!target_is_vim()) {
        CloseHandle(target_process);
        CloseHandle(mutex);
        return 5;
    }

    initial_foreground_window = GetForegroundWindow();
    find_target_or_terminal_window();

    keyboard_hook = SetWindowsHookExW(WH_KEYBOARD_LL, keyboard_proc, instance, 0);
    if (keyboard_hook == NULL) {
        CloseHandle(target_process);
        CloseHandle(mutex);
        return 6;
    }

    for (;;) {
        wait_result = MsgWaitForMultipleObjects(1, &target_process, FALSE, 50,
                                                QS_ALLINPUT);
        if (wait_result == WAIT_OBJECT_0) {
            break;
        }

        while (PeekMessageW(&message, NULL, 0, 0, PM_REMOVE)) {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }

        if (injected_ctrl && !target_is_foreground()) {
            release_ctrl();
        }
    }

    release_ctrl();
    UnhookWindowsHookEx(keyboard_hook);
    CloseHandle(target_process);
    ReleaseMutex(mutex);
    CloseHandle(mutex);
    return 0;
}
