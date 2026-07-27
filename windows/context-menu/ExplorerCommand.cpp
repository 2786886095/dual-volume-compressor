#define UNICODE
#define _UNICODE
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shobjidl.h>
#include <shlwapi.h>
#include <shellapi.h>
#include <string>
#include <vector>
#include <atomic>

namespace {

// {A238F665-74A4-4D0E-9F31-DA15BF81450B}
const CLSID CLSID_DualVolumeCommand =
{0xa238f665, 0x74a4, 0x4d0e, {0x9f, 0x31, 0xda, 0x15, 0xbf, 0x81, 0x45, 0x0b}};

HMODULE g_module = nullptr;
std::atomic<long> g_serverLocks{0};

std::wstring ModuleDirectory() {
    wchar_t buffer[MAX_PATH]{};
    const DWORD length = GetModuleFileNameW(g_module, buffer, ARRAYSIZE(buffer));
    std::wstring path(buffer, length);
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

HRESULT LaunchApplication(IShellItemArray* items) {
    if (!items) {
        return E_INVALIDARG;
    }

    DWORD count = 0;
    HRESULT hr = items->GetCount(&count);
    if (FAILED(hr) || count == 0) {
        return FAILED(hr) ? hr : E_INVALIDARG;
    }

    std::vector<std::wstring> paths;
    paths.reserve(count);
    for (DWORD index = 0; index < count; ++index) {
        IShellItem* item = nullptr;
        if (FAILED(items->GetItemAt(index, &item)) || !item) {
            continue;
        }

        PWSTR path = nullptr;
        if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &path)) && path) {
            paths.emplace_back(path);
            CoTaskMemFree(path);
        }
        item->Release();
    }

    if (paths.empty()) {
        return E_INVALIDARG;
    }

    const std::wstring launcher = ModuleDirectory() + L"\\DualVolumeLauncher.exe";
    std::wstring commandLine = QuoteArgument(launcher);
    for (const auto& path : paths) {
        commandLine.push_back(L' ');
        commandLine += QuoteArgument(path);
    }

    std::vector<wchar_t> mutableCommand(commandLine.begin(), commandLine.end());
    mutableCommand.push_back(L'\0');

    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION process{};
    const BOOL started = CreateProcessW(
        launcher.c_str(),
        mutableCommand.data(),
        nullptr,
        nullptr,
        FALSE,
        CREATE_NO_WINDOW,
        nullptr,
        ModuleDirectory().c_str(),
        &startup,
        &process);

    if (!started) {
        return HRESULT_FROM_WIN32(GetLastError());
    }

    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    return S_OK;
}

class ExplorerCommand final : public IExplorerCommand {
public:
    ExplorerCommand() : references_(1) { ++g_serverLocks; }
    ~ExplorerCommand() { --g_serverLocks; }

    IFACEMETHODIMP QueryInterface(REFIID iid, void** object) override {
        if (!object) return E_POINTER;
        *object = nullptr;
        if (IsEqualIID(iid, IID_IUnknown) || IsEqualIID(iid, IID_IExplorerCommand)) {
            *object = static_cast<IExplorerCommand*>(this);
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }

    IFACEMETHODIMP_(ULONG) AddRef() override { return ++references_; }

    IFACEMETHODIMP_(ULONG) Release() override {
        const ULONG remaining = --references_;
        if (remaining == 0) delete this;
        return remaining;
    }

    IFACEMETHODIMP GetTitle(IShellItemArray*, LPWSTR* title) override {
        return title ? SHStrDupW(L"用双层分卷压缩器打开", title) : E_POINTER;
    }

    IFACEMETHODIMP GetIcon(IShellItemArray*, LPWSTR* icon) override {
        if (!icon) return E_POINTER;
        const std::wstring iconPath =
            ModuleDirectory() + L"\\DualVolumeLauncher.exe,-101";
        return SHStrDupW(iconPath.c_str(), icon);
    }

    IFACEMETHODIMP GetToolTip(IShellItemArray*, LPWSTR* tooltip) override {
        return tooltip ? SHStrDupW(L"导入所选文件或文件夹", tooltip) : E_POINTER;
    }

    IFACEMETHODIMP GetCanonicalName(GUID* name) override {
        if (!name) return E_POINTER;
        *name = CLSID_DualVolumeCommand;
        return S_OK;
    }

    IFACEMETHODIMP GetState(IShellItemArray* items, BOOL, EXPCMDSTATE* state) override {
        if (!state) return E_POINTER;
        DWORD count = 0;
        *state = (items && SUCCEEDED(items->GetCount(&count)) && count > 0) ? ECS_ENABLED : ECS_HIDDEN;
        return S_OK;
    }

    IFACEMETHODIMP Invoke(IShellItemArray* items, IBindCtx*) override {
        return LaunchApplication(items);
    }

    IFACEMETHODIMP GetFlags(EXPCMDFLAGS* flags) override {
        if (!flags) return E_POINTER;
        *flags = ECF_DEFAULT;
        return S_OK;
    }

    IFACEMETHODIMP EnumSubCommands(IEnumExplorerCommand** commands) override {
        if (!commands) return E_POINTER;
        *commands = nullptr;
        return E_NOTIMPL;
    }

private:
    std::atomic<ULONG> references_;
};

class ClassFactory final : public IClassFactory {
public:
    ClassFactory() : references_(1) { ++g_serverLocks; }
    ~ClassFactory() { --g_serverLocks; }

    IFACEMETHODIMP QueryInterface(REFIID iid, void** object) override {
        if (!object) return E_POINTER;
        *object = nullptr;
        if (IsEqualIID(iid, IID_IUnknown) || IsEqualIID(iid, IID_IClassFactory)) {
            *object = static_cast<IClassFactory*>(this);
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }

    IFACEMETHODIMP_(ULONG) AddRef() override { return ++references_; }

    IFACEMETHODIMP_(ULONG) Release() override {
        const ULONG remaining = --references_;
        if (remaining == 0) delete this;
        return remaining;
    }

    IFACEMETHODIMP CreateInstance(IUnknown* outer, REFIID iid, void** object) override {
        if (outer) return CLASS_E_NOAGGREGATION;
        auto* command = new (std::nothrow) ExplorerCommand();
        if (!command) return E_OUTOFMEMORY;
        const HRESULT hr = command->QueryInterface(iid, object);
        command->Release();
        return hr;
    }

    IFACEMETHODIMP LockServer(BOOL lock) override {
        if (lock) ++g_serverLocks;
        else --g_serverLocks;
        return S_OK;
    }

private:
    std::atomic<ULONG> references_;
};

} // namespace

extern "C" HRESULT __stdcall DllGetClassObject(REFCLSID clsid, REFIID iid, void** object) {
    if (!IsEqualCLSID(clsid, CLSID_DualVolumeCommand)) return CLASS_E_CLASSNOTAVAILABLE;
    auto* factory = new (std::nothrow) ClassFactory();
    if (!factory) return E_OUTOFMEMORY;
    const HRESULT hr = factory->QueryInterface(iid, object);
    factory->Release();
    return hr;
}

extern "C" HRESULT __stdcall DllCanUnloadNow() {
    return g_serverLocks.load() == 0 ? S_OK : S_FALSE;
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        g_module = instance;
        DisableThreadLibraryCalls(instance);
    }
    return TRUE;
}
