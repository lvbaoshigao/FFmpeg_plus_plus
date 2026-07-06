#define _CRT_SECURE_NO_WARNINGS
#include "flutter_window.h"

#include <ole2.h>
#include <optional>
#include <shellapi.h>
#include <string>
#include <vector>
#include <cstdio>

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

// ---------- debug log ----------
static std::string DropLogPath() {
  const char* appdata = std::getenv("APPDATA");
  if (!appdata) appdata = "C:\\Temp";
  return std::string(appdata) + "\\FFmpeg++\\drop_debug.log";
}

static void DropLog(const char* fmt, ...) {
  static std::string path = DropLogPath();
  FILE* f = fopen(path.c_str(), "a");
  if (!f) return;
  SYSTEMTIME st;
  GetLocalTime(&st);
  fprintf(f, "[%02d:%02d:%02d.%03d] ",
          st.wHour, st.wMinute, st.wSecond, st.wMilliseconds);
  va_list ap;
  va_start(ap, fmt);
  vfprintf(f, fmt, ap);
  va_end(ap);
  fprintf(f, "\n");
  fclose(f);
}

static std::string WideToUtf8(const std::wstring& wide) {
  if (wide.empty()) return {};
  int size = WideCharToMultiByte(CP_UTF8, 0, wide.data(),
                                  (int)wide.size(), nullptr, 0, nullptr, nullptr);
  std::string result(size, 0);
  WideCharToMultiByte(CP_UTF8, 0, wide.data(), (int)wide.size(),
                      &result[0], size, nullptr, nullptr);
  return result;
}

// ---------- OLE IDropTarget ----------
class AppDropTarget : public IDropTarget {
 public:
  AppDropTarget(flutter::MethodChannel<flutter::EncodableValue>* ch,
                HWND hwnd)
      : channel_(ch), hwnd_(hwnd), ref_(1) {}

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** ppv) override {
    if (riid == IID_IDropTarget || riid == IID_IUnknown) {
      AddRef();
      *ppv = this;
      return S_OK;
    }
    *ppv = nullptr;
    return E_NOINTERFACE;
  }
  ULONG STDMETHODCALLTYPE AddRef() override {
    return InterlockedIncrement(&ref_);
  }
  ULONG STDMETHODCALLTYPE Release() override {
    LONG c = InterlockedDecrement(&ref_);
    if (c == 0) delete this;
    return c;
  }

  HRESULT STDMETHODCALLTYPE DragEnter(IDataObject*, DWORD,
                                      POINTL pt, DWORD* pdwEffect) override {
    DropLog("OLE DragEnter (%ld,%ld)", pt.x, pt.y);
    POINT p = {pt.x, pt.y};
    ScreenToClient(hwnd_, &p);
    channel_->InvokeMethod("entered",
        std::make_unique<flutter::EncodableValue>(flutter::EncodableList{
            flutter::EncodableValue(static_cast<double>(p.x)),
            flutter::EncodableValue(static_cast<double>(p.y)),
        }));
    *pdwEffect = DROPEFFECT_COPY;
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE DragOver(DWORD, POINTL pt,
                                     DWORD* pdwEffect) override {
    POINT p = {pt.x, pt.y};
    ScreenToClient(hwnd_, &p);
    channel_->InvokeMethod("updated",
        std::make_unique<flutter::EncodableValue>(flutter::EncodableList{
            flutter::EncodableValue(static_cast<double>(p.x)),
            flutter::EncodableValue(static_cast<double>(p.y)),
        }));
    *pdwEffect = DROPEFFECT_COPY;
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE DragLeave() override {
    DropLog("OLE DragLeave");
    channel_->InvokeMethod("exited",
        std::make_unique<flutter::EncodableValue>());
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE Drop(IDataObject* pDataObj, DWORD,
                                 POINTL pt, DWORD* pdwEffect) override {
    DropLog("OLE Drop (%ld,%ld)", pt.x, pt.y);
    flutter::EncodableList list;
    FORMATETC fmt = {CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
    STGMEDIUM stg;
    if (pDataObj->QueryGetData(&fmt) == S_OK &&
        pDataObj->GetData(&fmt, &stg) == S_OK) {
      PVOID data = GlobalLock(stg.hGlobal);
      if (data) {
        UINT count = DragQueryFileW(reinterpret_cast<HDROP>(data),
                                    0xFFFFFFFF, nullptr, 0);
        DropLog("OLE Drop %u files", count);
        for (UINT i = 0; i < count; i++) {
          UINT len = DragQueryFileW(reinterpret_cast<HDROP>(data),
                                    i, nullptr, 0);
          std::wstring path(len + 1, L'\0');
          DragQueryFileW(reinterpret_cast<HDROP>(data), i, &path[0], len + 1);
          path.resize(len);
          list.push_back(flutter::EncodableValue(WideToUtf8(path)));
        }
        GlobalUnlock(stg.hGlobal);
      }
      ReleaseStgMedium(&stg);
    }
    channel_->InvokeMethod("performOperation",
        std::make_unique<flutter::EncodableValue>(list));
    *pdwEffect = DROPEFFECT_COPY;
    return S_OK;
  }

 private:
  flutter::MethodChannel<flutter::EncodableValue>* channel_;
  HWND hwnd_;
  LONG ref_;
};

// -------------------------------------------------------------------------

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  DropLog("===== OnCreate START =====");

  RECT frame = GetClientArea();

  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    DropLog("FlutterViewController FAILED");
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  HWND child = flutter_controller_->view()->GetNativeWindow();
  SetChildContent(child);
  HWND top = GetHandle();
  DropLog("top=%p child=%p", top, child);

  // Method channel (same name as desktop_drop plugin)
  drop_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "desktop_drop",
      &flutter::StandardMethodCodec::GetInstance());

  // --- Primary: OLE IDropTarget on child window ---
  OleInitialize(nullptr);
  RevokeDragDrop(child);
  auto* target = new AppDropTarget(drop_channel_.get(), child);
  HRESULT hr = RegisterDragDrop(child, target);
  DropLog("RegisterDragDrop(child) = 0x%08lx", hr);
  target->Release();

  // Also register on top window
  RevokeDragDrop(top);
  auto* target2 = new AppDropTarget(drop_channel_.get(), top);
  hr = RegisterDragDrop(top, target2);
  DropLog("RegisterDragDrop(top) = 0x%08lx", hr);
  target2->Release();

  // --- Fallback: WM_DROPFILES for elevated processes ---
  // ChangeWindowMessageFilterEx allows WM_DROPFILES through UIPI
  // without calling DragAcceptFiles (which would revoke OLE registration).
  ChangeWindowMessageFilterEx(top, WM_DROPFILES, MSGFLT_ALLOW, nullptr);
  ChangeWindowMessageFilterEx(top, WM_COPYDATA, MSGFLT_ALLOW, nullptr);
  ChangeWindowMessageFilterEx(top, 0x0049, MSGFLT_ALLOW, nullptr);
  ChangeWindowMessageFilterEx(child, WM_DROPFILES, MSGFLT_ALLOW, nullptr);
  ChangeWindowMessageFilterEx(child, WM_COPYDATA, MSGFLT_ALLOW, nullptr);
  ChangeWindowMessageFilterEx(child, 0x0049, MSGFLT_ALLOW, nullptr);
  // Enable WM_DROPFILES on both windows (only effective when OLE is blocked)
  DragAcceptFiles(top, TRUE);
  DropLog("WM_DROPFILES fallback configured");

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });
  flutter_controller_->ForceRedraw();

  DropLog("===== OnCreate END =====");
  return true;
}

void FlutterWindow::OnDestroy() {
  DropLog("OnDestroy");
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }
  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;

    case WM_DROPFILES: {
      DropLog("WM_DROPFILES on hwnd=%p", hwnd);
      HDROP hDrop = reinterpret_cast<HDROP>(wparam);
      if (drop_channel_) {
        POINT pt;
        DragQueryPoint(hDrop, &pt);
        drop_channel_->InvokeMethod("entered",
            std::make_unique<flutter::EncodableValue>(flutter::EncodableList{
                flutter::EncodableValue(static_cast<double>(pt.x)),
                flutter::EncodableValue(static_cast<double>(pt.y)),
            }));

        UINT count = DragQueryFileW(hDrop, 0xFFFFFFFF, nullptr, 0);
        DropLog("WM_DROPFILES %u files", count);
        flutter::EncodableList files;
        for (UINT i = 0; i < count; i++) {
          UINT len = DragQueryFileW(hDrop, i, nullptr, 0);
          std::wstring path(len + 1, L'\0');
          DragQueryFileW(hDrop, i, &path[0], len + 1);
          path.resize(len);
          files.push_back(flutter::EncodableValue(WideToUtf8(path)));
        }
        drop_channel_->InvokeMethod("performOperation",
            std::make_unique<flutter::EncodableValue>(files));
      }
      DragFinish(reinterpret_cast<HDROP>(wparam));
      return 0;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
