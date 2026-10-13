#include <winsock2.h>
#include <ws2ipdef.h>
#include <windows.h>
#include <shellapi.h>
#include <iphlpapi.h>
#include <netioapi.h>
#include <winrt/Windows.Data.Json.h>
#include <winrt/Windows.Foundation.h>

#include <algorithm>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include "resource.h"
#include "flutter/ephemeral/.plugin_symlinks/flutter_local_notifications_windows/src/ffi_api.h"

namespace {
constexpr UINT kTrayMessage = WM_APP + 1;
constexpr UINT kReceiverMessage = WM_APP + 2;
constexpr UINT kReceiverStopped = WM_APP + 3;
constexpr UINT kActivationMessage = WM_APP + 4;
constexpr UINT kNetworkMessage = WM_APP + 5;
constexpr UINT kUiStopped = WM_APP + 6;
constexpr UINT kMessages = 1;
constexpr UINT kSettings = 2;
constexpr UINT kExit = 3;
constexpr UINT_PTR kProcessTimer = 1;
constexpr UINT_PTR kShutdownTimer = 2;
constexpr UINT_PTR kUiTimer = 3;
constexpr wchar_t kHostClass[] = L"TUG_WINDOWS_HOST";
constexpr wchar_t kGuid[] = L"e6c0bfad-eae8-4cea-8af3-88919c472881";

using winrt::Windows::Data::Json::JsonObject;
using winrt::Windows::Data::Json::JsonValue;

std::wstring executable;
HWND host_window = nullptr;
HANDLE receiver_process = nullptr;
HANDLE receiver_input = nullptr;
HANDLE receiver_output = nullptr;
HANDLE ui_process = nullptr;
HANDLE ui_wait = nullptr;
HANDLE child_job = nullptr;
HANDLE network_notification = nullptr;
std::thread receiver_reader;
NOTIFYICONDATAW tray = {};
bool tray_ready = false;
bool ready = false;
bool exiting = false;
bool ui_requested = false;
DWORD ui_process_id = 0;
std::string pending_page = "messages";
std::string pending_message;
int port = 0;
std::string capability;
int notification_id = 0;
HMODULE notification_library = nullptr;
NativePlugin* notification_plugin = nullptr;
decltype(&createPlugin) create_plugin = nullptr;
decltype(&disposePlugin) dispose_plugin = nullptr;
decltype(&init) initialize_plugin = nullptr;
decltype(&showNotification) show_notification = nullptr;
decltype(&freeLaunchDetails) free_launch_details = nullptr;

std::wstring Directory() {
  return executable.substr(0, executable.find_last_of(L"\\/"));
}

std::wstring RuntimeDirectory() {
  return Directory() + L"\\runtime";
}

bool Write(HANDLE pipe, const std::string& message) {
  DWORD written = 0;
  return pipe != nullptr && WriteFile(pipe, message.data(),
      static_cast<DWORD>(message.size()), &written, nullptr) && written == message.size();
}

void Send(JsonObject command) {
  Write(receiver_input, winrt::to_string(command.Stringify()) + "\n");
}

void SendType(const wchar_t* type) {
  JsonObject command;
  command.SetNamedValue(L"type", JsonValue::CreateStringValue(type));
  Send(command);
}

void Report(const wchar_t* message) {
  MessageBoxW(host_window, message, L"Tug", MB_OK | MB_ICONERROR);
}

bool StartChild(const std::wstring& command, HANDLE input, HANDLE output,
                HANDLE error, PROCESS_INFORMATION& process) {
  SIZE_T size = 0;
  InitializeProcThreadAttributeList(nullptr, 1, 0, &size);
  std::vector<unsigned char> attributes(size);
  STARTUPINFOEXW startup = {};
  startup.StartupInfo.cb = sizeof(startup);
  startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
  startup.StartupInfo.hStdInput = input;
  startup.StartupInfo.hStdOutput = output;
  startup.StartupInfo.hStdError = error;
  startup.lpAttributeList = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(attributes.data());
  if (!InitializeProcThreadAttributeList(startup.lpAttributeList, 1, 0, &size)) return false;
  HANDLE handles[] = {input, output, error};
  const bool updated = UpdateProcThreadAttribute(startup.lpAttributeList, 0,
      PROC_THREAD_ATTRIBUTE_HANDLE_LIST, handles, sizeof(handles), nullptr, nullptr) != FALSE;
  auto mutable_command = command;
  const bool created = updated && CreateProcessW(nullptr, mutable_command.data(), nullptr,
      nullptr, TRUE, CREATE_NO_WINDOW | CREATE_SUSPENDED | EXTENDED_STARTUPINFO_PRESENT,
      nullptr, RuntimeDirectory().c_str(), &startup.StartupInfo, &process) != FALSE;
  DeleteProcThreadAttributeList(startup.lpAttributeList);
  if (!created) return false;
  if (!AssignProcessToJobObject(child_job, process.hProcess)) {
    TerminateProcess(process.hProcess, EXIT_FAILURE);
    CloseHandle(process.hProcess);
    CloseHandle(process.hThread);
    return false;
  }
  ResumeThread(process.hThread);
  CloseHandle(process.hThread);
  return true;
}

BOOL CALLBACK FindUi(HWND window, LPARAM result) {
  DWORD process = 0;
  GetWindowThreadProcessId(window, &process);
  wchar_t name[64] = {};
  GetClassNameW(window, name, 64);
  if (process == ui_process_id && std::wstring(name) == L"FLUTTER_RUNNER_WIN32_WINDOW") {
    *reinterpret_cast<HWND*>(result) = window;
    return FALSE;
  }
  return TRUE;
}

HWND UiWindow() {
  HWND result = nullptr;
  if (ui_process != nullptr) EnumWindows(FindUi, reinterpret_cast<LPARAM>(&result));
  return result;
}

bool UiAlive() {
  if (ui_process == nullptr) return false;
  if (WaitForSingleObject(ui_process, 0) == WAIT_TIMEOUT) return true;
  if (ui_wait != nullptr) {
    UnregisterWaitEx(ui_wait, INVALID_HANDLE_VALUE);
    ui_wait = nullptr;
  }
  CloseHandle(ui_process);
  ui_process = nullptr;
  ui_process_id = 0;
  return false;
}

void CALLBACK UiStopped(void*, BOOLEAN) {
  PostMessageW(host_window, kUiStopped, 0, 0);
}

bool DeliverPage(HWND window) {
  const auto request = pending_page + "\t" + pending_message;
  COPYDATASTRUCT data = {0x545547, static_cast<DWORD>(request.size() + 1),
      const_cast<char*>(request.c_str())};
  DWORD_PTR response = 0;
  return SendMessageTimeoutW(window, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&data),
      SMTO_ABORTIFHUNG, 1000, &response) != 0 && response != 0;
}

void OpenUi(const std::string& page, const std::string& message = "") {
  pending_page = page;
  pending_message = message;
  ui_requested = true;
  if (!ready || exiting) return;
  if (UiAlive()) {
    const auto window = UiWindow();
    if (window != nullptr && DeliverPage(window)) {
      ui_requested = false;
      KillTimer(host_window, kProcessTimer);
      ShowWindow(window, SW_RESTORE);
      SetForegroundWindow(window);
    }
    if (ui_requested) SetTimer(host_window, kProcessTimer, 100, nullptr);
    return;
  }
  SECURITY_ATTRIBUTES security = {sizeof(security), nullptr, TRUE};
  HANDLE input = nullptr;
  HANDLE output = nullptr;
  if (!CreatePipe(&input, &output, &security, 0)) { Report(L"Cannot open the UI pipe."); return; }
  SetHandleInformation(output, HANDLE_FLAG_INHERIT, 0);
  const auto null_output = CreateFileW(L"NUL", GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
      &security, OPEN_EXISTING, 0, nullptr);
  const auto null_error = CreateFileW(L"NUL", GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
      &security, OPEN_EXISTING, 0, nullptr);
  PROCESS_INFORMATION process = {};
  const bool started = StartChild(L"\"" + RuntimeDirectory() + L"\\tug-ui.exe\" --hosted", input,
      null_output, null_error, process);
  CloseHandle(input);
  CloseHandle(null_output);
  CloseHandle(null_error);
  if (started) {
    ui_process = process.hProcess;
    ui_process_id = process.dwProcessId;
    AllowSetForegroundWindow(ui_process_id);
    RegisterWaitForSingleObject(&ui_wait, ui_process, UiStopped, nullptr, INFINITE, WT_EXECUTEONLYONCE);
    const auto launch = std::to_string(port) + "\n" + capability + "\n" +
        pending_page + "\t" + pending_message + "\n";
    if (!Write(output, launch)) TerminateProcess(ui_process, EXIT_FAILURE);
    ui_requested = false;
    KillTimer(host_window, kProcessTimer);
    SetTimer(host_window, kUiTimer, 30000, nullptr);
  } else {
    ui_requested = false;
    KillTimer(host_window, kProcessTimer);
    Report(L"Cannot open Tug's window. Keep tug.exe and the complete runtime folder together.");
  }
  CloseHandle(output);
}

std::string EscapeXml(const std::string& input) {
  std::string output;
  for (const auto character : input) {
    switch (character) {
      case '&': output += "&amp;"; break;
      case '<': output += "&lt;"; break;
      case '>': output += "&gt;"; break;
      case '"': output += "&quot;"; break;
      case '\'': output += "&apos;"; break;
      default: output += character; break;
    }
  }
  return output;
}

void Activated(NativeLaunchDetails details) {
  auto payload = std::make_unique<std::string>(details.payload == nullptr ? "" : details.payload);
  free_launch_details(details);
  if (PostMessageW(host_window, kActivationMessage, 0, reinterpret_cast<LPARAM>(payload.get()))) {
    payload.release();
  }
}

bool InitializeNotifications() {
  const auto path = L"Software\\Classes\\CLSID\\{" + std::wstring(kGuid) + L"}\\LocalServer32";
  HKEY key = nullptr;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, path.c_str(), 0, nullptr, 0, KEY_SET_VALUE,
      nullptr, &key, nullptr) != ERROR_SUCCESS) return false;
  const auto command = L"\"" + executable + L"\" --notification-activation";
  const auto registered = RegSetValueExW(key, L"", 0, REG_SZ,
      reinterpret_cast<const BYTE*>(command.c_str()),
      static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
  RegCloseKey(key);
  if (registered != ERROR_SUCCESS) return false;
  notification_library = LoadLibraryW((RuntimeDirectory() + L"\\flutter_local_notifications_windows.dll").c_str());
  if (notification_library == nullptr) return false;
  create_plugin = reinterpret_cast<decltype(create_plugin)>(GetProcAddress(notification_library, "createPlugin"));
  dispose_plugin = reinterpret_cast<decltype(dispose_plugin)>(GetProcAddress(notification_library, "disposePlugin"));
  initialize_plugin = reinterpret_cast<decltype(initialize_plugin)>(GetProcAddress(notification_library, "init"));
  show_notification = reinterpret_cast<decltype(show_notification)>(GetProcAddress(notification_library, "showNotification"));
  free_launch_details = reinterpret_cast<decltype(free_launch_details)>(GetProcAddress(notification_library, "freeLaunchDetails"));
  if (!create_plugin || !dispose_plugin || !initialize_plugin || !show_notification || !free_launch_details) return false;
  try {
    notification_plugin = create_plugin();
    std::string name = "Tug";
    std::string app_id = "Tug.Client.Windows";
    auto guid = winrt::to_string(kGuid);
    auto icon = winrt::to_string(RuntimeDirectory() + L"\\data\\flutter_assets\\assets\\tug.ico");
    return initialize_plugin(notification_plugin, name.data(), app_id.data(), guid.data(), icon.data(), Activated);
  } catch (...) { return false; }
}

void ReceiverEvent(const std::string& line) {
  try {
    const auto event = JsonObject::Parse(winrt::to_hstring(line));
    const auto type = event.GetNamedString(L"type");
    if (type == L"ready") {
      port = static_cast<int>(event.GetNamedNumber(L"port"));
      capability = winrt::to_string(event.GetNamedString(L"capability"));
      ready = true;
      JsonObject status;
      status.SetNamedValue(L"type", JsonValue::CreateStringValue(L"notification_status"));
      status.SetNamedValue(L"diagnostic", notification_plugin == nullptr
          ? JsonValue::CreateStringValue(L"System notifications are unavailable.")
          : JsonValue::CreateNullValue());
      Send(status);
      if (event.GetNamedBoolean(L"needs_ui") || ui_requested || !tray_ready) {
        OpenUi(event.GetNamedBoolean(L"needs_ui") ? "settings" : pending_page, pending_message);
      }
    } else if (type == L"notification") {
      bool shown = false;
      if (notification_plugin != nullptr) {
        const auto id = winrt::to_string(event.GetNamedString(L"id"));
        auto xml = "<toast launch=\"" + EscapeXml(id) + "\"><visual><binding template=\"ToastGeneric\">" +
            "<text>" + EscapeXml(winrt::to_string(event.GetNamedString(L"title"))) + "</text><text>" +
            EscapeXml(winrt::to_string(event.GetNamedString(L"body"))) + "</text></binding></visual></toast>";
        try {
          notification_id = (notification_id + 1) % 20;
          shown = show_notification(notification_plugin, notification_id, xml.data(), {nullptr, 0});
        } catch (...) {}
      }
      JsonObject result;
      result.SetNamedValue(L"type", JsonValue::CreateStringValue(L"notification_result"));
      result.SetNamedValue(L"request", event.GetNamedValue(L"request"));
      result.SetNamedValue(L"ok", JsonValue::CreateBooleanValue(shown));
      Send(result);
    }
  } catch (...) {
    Report(L"Receive host protocol failed. Exit Tug and reopen the complete Release directory.");
  }
}

void AddTray() {
  tray.cbSize = sizeof(tray);
  tray.hWnd = host_window;
  tray.uID = 1;
  tray.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  tray.uCallbackMessage = kTrayMessage;
  tray.hIcon = LoadIconW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON));
  wcscpy_s(tray.szTip, L"Tug");
  tray_ready = Shell_NotifyIconW(NIM_ADD, &tray) != FALSE;
  tray.uVersion = NOTIFYICON_VERSION_4;
  if (tray_ready) Shell_NotifyIconW(NIM_SETVERSION, &tray);
}

void BeginExit() {
  if (exiting) return;
  exiting = true;
  Shell_NotifyIconW(NIM_DELETE, &tray);
  if (UiAlive()) {
    const auto window = UiWindow();
    if (window != nullptr) PostMessageW(window, WM_CLOSE, 0, 0);
  }
  SendType(L"shutdown");
  SetTimer(host_window, kShutdownTimer, 10000, nullptr);
}

void CALLBACK NetworkChanged(void*, MIB_IPINTERFACE_ROW*, MIB_NOTIFICATION_TYPE) {
  PostMessageW(host_window, kNetworkMessage, 0, 0);
}

void UpdateNetwork() {
  MIB_IF_TABLE2* table = nullptr;
  bool available = false;
  if (GetIfTable2(&table) == NO_ERROR) {
    for (ULONG index = 0; index < table->NumEntries; ++index) {
      const auto& adapter = table->Table[index];
      if (adapter.Type != IF_TYPE_SOFTWARE_LOOPBACK && adapter.OperStatus == IfOperStatusUp) {
        available = true;
        break;
      }
    }
    FreeMibTable(table);
  } else {
    SendType(L"resume");
    return;
  }
  JsonObject command;
  command.SetNamedValue(L"type", JsonValue::CreateStringValue(L"network"));
  command.SetNamedValue(L"available", JsonValue::CreateBooleanValue(available));
  Send(command);
}

LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM parameter, LPARAM data) {
  static const UINT taskbar_created = RegisterWindowMessageW(L"TaskbarCreated");
  if (message == taskbar_created) { AddTray(); return 0; }
  switch (message) {
    case kTrayMessage:
      if (LOWORD(data) == WM_LBUTTONDBLCLK || LOWORD(data) == NIN_KEYSELECT) OpenUi("messages");
      if (LOWORD(data) == WM_CONTEXTMENU) {
        const auto menu = CreatePopupMenu();
        AppendMenuW(menu, MF_STRING, kMessages, L"Messages");
        AppendMenuW(menu, MF_STRING, kSettings, L"Settings");
        AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
        AppendMenuW(menu, MF_STRING, kExit, L"Exit");
        POINT position;
        GetCursorPos(&position);
        SetForegroundWindow(window);
        const auto selection = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON,
            position.x, position.y, 0, window, nullptr);
        DestroyMenu(menu);
        PostMessageW(window, WM_NULL, 0, 0);
        if (selection == kMessages) OpenUi("messages");
        if (selection == kSettings) OpenUi("settings");
        if (selection == kExit) BeginExit();
      }
      return 0;
    case WM_COPYDATA: {
      const auto request = reinterpret_cast<const COPYDATASTRUCT*>(data);
      if (request == nullptr || request->dwData != 0x545547 || request->lpData == nullptr ||
          request->cbData == 0 || request->cbData > 64) return FALSE;
      const auto bytes = static_cast<const char*>(request->lpData);
      if (bytes[request->cbData - 1] != '\0') return FALSE;
      const std::string launch(bytes, request->cbData - 1);
      if (launch == "manual") OpenUi("messages");
      else if (launch == "activation") OpenUi("messages", "unavailable-after-restart");
      else if (launch != "background") return FALSE;
      return TRUE;
    }
    case kReceiverMessage: {
      const std::unique_ptr<std::string> line(reinterpret_cast<std::string*>(data));
      ReceiverEvent(*line);
      return 0;
    }
    case kActivationMessage: {
      const std::unique_ptr<std::string> payload(reinterpret_cast<std::string*>(data));
      OpenUi("messages", *payload);
      return 0;
    }
    case kReceiverStopped:
      if (!exiting) Report(L"The receive host stopped unexpectedly. Reopen Tug to resume receiving.");
      PostQuitMessage(exiting ? EXIT_SUCCESS : EXIT_FAILURE);
      return 0;
    case kNetworkMessage:
      if (!exiting) UpdateNetwork();
      return 0;
    case kUiStopped:
      KillTimer(host_window, kUiTimer);
      if (!exiting && !UiAlive()) {
        if (!tray_ready) BeginExit();
        else if (ui_requested) OpenUi(pending_page, pending_message);
      }
      return 0;
    case WM_POWERBROADCAST:
      if (parameter == PBT_APMRESUMEAUTOMATIC && !exiting) SendType(L"resume");
      return TRUE;
    case WM_TIMER:
      if (parameter == kShutdownTimer) PostQuitMessage(EXIT_SUCCESS);
      if (parameter == kProcessTimer) {
        if (exiting || !ui_requested) { KillTimer(window, kProcessTimer); return 0; }
        if (ui_requested && ready) OpenUi(pending_page, pending_message);
      }
      if (parameter == kUiTimer) {
        KillTimer(host_window, kUiTimer);
        const auto ui_window = UiWindow();
        if (UiAlive() && (ui_window == nullptr || !IsWindowVisible(ui_window))) {
          TerminateProcess(ui_process, EXIT_FAILURE);
          Report(L"The UI did not start. Receiving continues; try opening Settings again.");
        }
      }
      return 0;
    case WM_CLOSE:
      BeginExit();
      return 0;
    case WM_QUERYENDSESSION:
      return TRUE;
    case WM_ENDSESSION:
      if (parameter) {
        SendType(L"shutdown");
        PostQuitMessage(EXIT_SUCCESS);
      }
      return 0;
  }
  return DefWindowProcW(window, message, parameter, data);
}

bool StartReceiver() {
  SECURITY_ATTRIBUTES security = {sizeof(security), nullptr, TRUE};
  HANDLE input = nullptr;
  HANDLE output = nullptr;
  if (!CreatePipe(&input, &receiver_input, &security, 0)) return false;
  if (!CreatePipe(&receiver_output, &output, &security, 0)) { CloseHandle(input); return false; }
  SetHandleInformation(receiver_input, HANDLE_FLAG_INHERIT, 0);
  SetHandleInformation(receiver_output, HANDLE_FLAG_INHERIT, 0);
  const auto error = CreateFileW(L"NUL", GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
      &security, OPEN_EXISTING, 0, nullptr);
  PROCESS_INFORMATION process = {};
  const bool started = StartChild(L"\"" + RuntimeDirectory() + L"\\tug-receiver.exe\" \"" + executable + L"\"",
      input, output, error, process);
  CloseHandle(input);
  CloseHandle(output);
  CloseHandle(error);
  if (!started) return false;
  receiver_process = process.hProcess;
  receiver_reader = std::thread([] {
    std::string pending;
    char buffer[8192];
    DWORD read = 0;
    while (ReadFile(receiver_output, buffer, sizeof(buffer), &read, nullptr) && read > 0) {
      pending.append(buffer, read);
      if (pending.size() > 2 * 1024 * 1024) break;
      size_t newline;
      while ((newline = pending.find('\n')) != std::string::npos) {
        auto line = std::make_unique<std::string>(pending.substr(0, newline));
        pending.erase(0, newline + 1);
        if (PostMessageW(host_window, kReceiverMessage, 0, reinterpret_cast<LPARAM>(line.get()))) line.release();
      }
    }
    PostMessageW(host_window, kReceiverStopped, 0, 0);
  });
  return true;
}
}

int APIENTRY wWinMain(HINSTANCE instance, HINSTANCE, wchar_t*, int) {
  std::vector<wchar_t> path(32768);
  const auto length = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
  if (length == 0 || length == path.size()) return EXIT_FAILURE;
  executable.assign(path.data(), length);
  int count = 0;
  const auto arguments = CommandLineToArgvW(GetCommandLineW(), &count);
  bool background = false;
  bool activation = false;
  for (int index = 1; index < count; ++index) {
    background |= std::wstring(arguments[index]) == L"--background";
    activation |= std::wstring(arguments[index]) == L"--notification-activation";
  }
  LocalFree(arguments);
  const auto singleton = CreateMutexW(nullptr, FALSE, L"Local\\Tug.Client.Windows.Singleton.v1");
  if (singleton == nullptr) return EXIT_FAILURE;
  if (GetLastError() == ERROR_ALREADY_EXISTS) {
    const std::string request = activation ? "activation" : background ? "background" : "manual";
    bool delivered = false;
    for (int attempt = 0; attempt < 100 && !delivered; ++attempt) {
      auto target = FindWindowW(kHostClass, L"Tug");
      if (target == nullptr) target = FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"Tug");
      if (target != nullptr) {
        DWORD target_process = 0;
        GetWindowThreadProcessId(target, &target_process);
        AllowSetForegroundWindow(target_process);
        COPYDATASTRUCT data = {0x545547, static_cast<DWORD>(request.size() + 1), const_cast<char*>(request.c_str())};
        DWORD_PTR response = 0;
        delivered = SendMessageTimeoutW(target, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&data),
            SMTO_ABORTIFHUNG, 1000, &response) != 0 && response != 0;
      }
      if (!delivered) Sleep(50);
    }
    CloseHandle(singleton);
    return delivered ? EXIT_SUCCESS : EXIT_FAILURE;
  }
  winrt::init_apartment(winrt::apartment_type::single_threaded);
  WNDCLASSW window_class = {};
  window_class.lpfnWndProc = WindowProc;
  window_class.hInstance = instance;
  window_class.lpszClassName = kHostClass;
  RegisterClassW(&window_class);
  host_window = CreateWindowW(kHostClass, L"Tug", WS_OVERLAPPED, 0, 0, 0, 0, nullptr, nullptr, instance, nullptr);
  if (host_window == nullptr) { CloseHandle(singleton); return EXIT_FAILURE; }
  child_job = CreateJobObjectW(nullptr, nullptr);
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {};
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (child_job == nullptr || !SetInformationJobObject(child_job, JobObjectExtendedLimitInformation, &limits, sizeof(limits))) {
    Report(L"Cannot create the receive host job.");
    if (child_job) CloseHandle(child_job);
    CloseHandle(singleton);
    return EXIT_FAILURE;
  }
  AddTray();
  if (!InitializeNotifications() && notification_plugin != nullptr) {
    dispose_plugin(notification_plugin);
    notification_plugin = nullptr;
  }
  ui_requested = !background || activation;
  if (activation) pending_message = "unavailable-after-restart";
  if (!StartReceiver()) {
    Report(L"Cannot start Tug's receiver. Keep tug.exe and the complete runtime folder together.");
    Shell_NotifyIconW(NIM_DELETE, &tray);
    CloseHandle(child_job);
    CloseHandle(singleton);
    return EXIT_FAILURE;
  }
  NotifyIpInterfaceChange(AF_UNSPEC, NetworkChanged, nullptr, TRUE, &network_notification);
  MSG message = {};
  while (GetMessageW(&message, nullptr, 0, 0) > 0) {
    TranslateMessage(&message);
    DispatchMessageW(&message);
  }
  if (network_notification != nullptr) CancelMibChangeNotify2(network_notification);
  Shell_NotifyIconW(NIM_DELETE, &tray);
  CloseHandle(child_job);
  if (ui_wait != nullptr) UnregisterWaitEx(ui_wait, INVALID_HANDLE_VALUE);
  if (receiver_reader.joinable()) receiver_reader.join();
  CloseHandle(receiver_input);
  CloseHandle(receiver_output);
  CloseHandle(receiver_process);
  if (ui_process != nullptr) CloseHandle(ui_process);
  if (notification_plugin != nullptr) dispose_plugin(notification_plugin);
  DestroyWindow(host_window);
  CloseHandle(singleton);
  winrt::uninit_apartment();
  return static_cast<int>(message.wParam);
}
