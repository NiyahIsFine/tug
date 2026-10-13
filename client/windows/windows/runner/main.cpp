#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <filesystem>
#include <string>
#include <vector>

#include "flutter_window.h"
#include "utils.h"

namespace {
int LaunchHost(const std::filesystem::path& directory) {
  const auto host_directory = directory.parent_path().wstring();
  const auto host_executable = (directory.parent_path() / L"tug.exe").wstring();
  auto command = L"\"" + host_executable + L"\"";
  STARTUPINFOW startup = {};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process = {};
  if (!::CreateProcessW(host_executable.c_str(), command.data(), nullptr, nullptr,
                       FALSE, 0, nullptr, host_directory.c_str(), &startup, &process)) {
    ::MessageBoxW(nullptr, L"Cannot open Tug. Keep tug.exe and the complete runtime folder together.",
                  L"Tug", MB_OK | MB_ICONERROR);
    return EXIT_FAILURE;
  }
  ::AllowSetForegroundWindow(process.dwProcessId);
  ::CloseHandle(process.hThread);
  ::CloseHandle(process.hProcess);
  return EXIT_SUCCESS;
}
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  std::vector<wchar_t> executable(32768);
  const auto length = ::GetModuleFileNameW(nullptr, executable.data(),
                                         static_cast<DWORD>(executable.size()));
  if (length == 0 || length == executable.size()) return EXIT_FAILURE;
  const auto directory = std::filesystem::path(std::wstring(executable.data(), length)).parent_path();
  std::vector<std::string> arguments;
  const auto input = ::GetStdHandle(STD_INPUT_HANDLE);
  if (std::wstring(command_line) != L"--hosted" || ::GetFileType(input) != FILE_TYPE_PIPE) {
    return LaunchHost(directory);
  }
  std::string line;
  char character = 0;
  DWORD read = 0;
  while (arguments.size() < 3 && ::ReadFile(input, &character, 1, &read, nullptr) && read == 1) {
    if (character == '\n') {
      arguments.push_back(line);
      line.clear();
    } else {
      line += character;
      if (line.size() > 512) return EXIT_FAILURE;
    }
  }
  if (arguments.size() != 3) return EXIT_FAILURE;
  ::CloseHandle(input);
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project((directory / L"data").wstring());

  project.set_dart_entrypoint_arguments(std::move(arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(720, 640);
  if (!window.Create(L"Tug", origin, size)) {
    ::CoUninitialize();
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
