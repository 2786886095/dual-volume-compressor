#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h>
#include <string>
#include <vector>

namespace {

std::wstring ParentPath(const std::wstring& path) {
    const auto slash = path.find_last_of(L"\\/");
    return slash == std::wstring::npos ? std::wstring() : path.substr(0, slash);
}

std::wstring QuoteArgument(const std::wstring& value) {
    std::wstring result = L"\"";
    size_t slashes = 0;
    for (const wchar_t ch : value) {
        if (ch == L'\\') {
            ++slashes;
        } else if (ch == L'\"') {
            result.append(slashes * 2 + 1, L'\\');
            result.push_back(L'\"');
            slashes = 0;
        } else {
            result.append(slashes, L'\\');
            slashes = 0;
            result.push_back(ch);
        }
    }
    result.append(slashes * 2, L'\\');
    result.push_back(L'\"');
    return result;
}

} // namespace

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
    wchar_t moduleBuffer[MAX_PATH]{};
    const DWORD moduleLength = GetModuleFileNameW(nullptr, moduleBuffer, ARRAYSIZE(moduleBuffer));
    const std::wstring modulePath(moduleBuffer, moduleLength);
    const std::wstring appRoot = ParentPath(ParentPath(ParentPath(modulePath)));
    const std::wstring scriptPath = appRoot + L"\\DualVolumeCompressor.ps1";

    if (GetFileAttributesW(scriptPath.c_str()) == INVALID_FILE_ATTRIBUTES) {
        MessageBoxW(nullptr, L"找不到 DualVolumeCompressor.ps1。请保持项目目录结构完整。", L"双层分卷压缩器", MB_OK | MB_ICONERROR);
        return 2;
    }

    wchar_t systemDirectory[MAX_PATH]{};
    GetSystemDirectoryW(systemDirectory, ARRAYSIZE(systemDirectory));
    const std::wstring powershell = std::wstring(systemDirectory) + L"\\WindowsPowerShell\\v1.0\\powershell.exe";

    int argumentCount = 0;
    LPWSTR* arguments = CommandLineToArgvW(GetCommandLineW(), &argumentCount);
    std::wstring commandLine = QuoteArgument(powershell) +
        L" -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File " + QuoteArgument(scriptPath);
    for (int index = 1; index < argumentCount; ++index) {
        commandLine.push_back(L' ');
        commandLine += QuoteArgument(arguments[index]);
    }
    if (arguments) LocalFree(arguments);

    std::vector<wchar_t> mutableCommand(commandLine.begin(), commandLine.end());
    mutableCommand.push_back(L'\0');
    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION process{};
    const BOOL started = CreateProcessW(
        powershell.c_str(), mutableCommand.data(), nullptr, nullptr, FALSE,
        CREATE_NO_WINDOW, nullptr, appRoot.c_str(), &startup, &process);

    if (!started) {
        MessageBoxW(nullptr, L"启动 PowerShell 界面失败。", L"双层分卷压缩器", MB_OK | MB_ICONERROR);
        return static_cast<int>(GetLastError());
    }

    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    return 0;
}
