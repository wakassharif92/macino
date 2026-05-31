#include "local_screen_share_controller.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <chrono>
#include <sstream>
#include <variant>

#include <windows.h>
#include <guiddef.h>
#include <unknwn.h>
#include <objbase.h>
#include <iphlpapi.h>
#include <objidl.h>
#include <propidl.h>
#include <gdiplus.h>
#include <ws2tcpip.h>

namespace {

constexpr uint16_t kPort = 41873;

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) {
    return "";
  }
  const int size = WideCharToMultiByte(CP_UTF8, 0, value.data(),
                                       static_cast<int>(value.size()), nullptr,
                                       0, nullptr, nullptr);
  std::string result(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
                      result.data(), size, nullptr, nullptr);
  return result;
}

std::string LastErrorMessage(const std::string& fallback) {
  wchar_t* buffer = nullptr;
  const DWORD error = GetLastError();
  FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
                     FORMAT_MESSAGE_IGNORE_INSERTS,
                 nullptr, error, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
                 reinterpret_cast<LPWSTR>(&buffer), 0, nullptr);
  if (!buffer) {
    return fallback;
  }
  std::wstring message(buffer);
  LocalFree(buffer);
  while (!message.empty() &&
         (message.back() == L'\r' || message.back() == L'\n' ||
          message.back() == L' ')) {
    message.pop_back();
  }
  return message.empty() ? fallback : WideToUtf8(message);
}

bool IsPrivateIPv4(const std::string& ip) {
  if (ip == "127.0.0.1") {
    return true;
  }
  if (ip.rfind("10.", 0) == 0 || ip.rfind("192.168.", 0) == 0 ||
      ip.rfind("169.254.", 0) == 0) {
    return true;
  }

  unsigned int a = 0;
  unsigned int b = 0;
  unsigned int c = 0;
  unsigned int d = 0;
  if (sscanf_s(ip.c_str(), "%u.%u.%u.%u", &a, &b, &c, &d) == 4) {
    return a == 172 && b >= 16 && b <= 31;
  }
  return false;
}

bool GetJpegEncoderClsid(CLSID* clsid) {
  UINT count = 0;
  UINT size = 0;
  Gdiplus::GetImageEncodersSize(&count, &size);
  if (size == 0) {
    return false;
  }

  std::vector<uint8_t> buffer(size);
  auto* encoders =
      reinterpret_cast<Gdiplus::ImageCodecInfo*>(buffer.data());
  if (Gdiplus::GetImageEncoders(count, size, encoders) != Gdiplus::Ok) {
    return false;
  }

  for (UINT i = 0; i < count; ++i) {
    if (wcscmp(encoders[i].MimeType, L"image/jpeg") == 0) {
      *clsid = encoders[i].Clsid;
      return true;
    }
  }
  return false;
}

flutter::EncodableMap StatusPayload(bool is_sharing,
                                    const std::string& message,
                                    const std::string& url) {
  return flutter::EncodableMap{
      {flutter::EncodableValue("isSharing"), flutter::EncodableValue(is_sharing)},
      {flutter::EncodableValue("message"), flutter::EncodableValue(message)},
      {flutter::EncodableValue("url"), flutter::EncodableValue(url)},
      {flutter::EncodableValue("port"), flutter::EncodableValue(kPort)},
  };
}

std::string UrlDecode(std::string value) {
  std::string decoded;
  for (size_t i = 0; i < value.size(); ++i) {
    if (value[i] == '%' && i + 2 < value.size()) {
      unsigned int ch = 0;
      if (sscanf_s(value.substr(i + 1, 2).c_str(), "%x", &ch) == 1) {
        decoded.push_back(static_cast<char>(ch));
        i += 2;
        continue;
      }
    }
    decoded.push_back(value[i] == '+' ? ' ' : value[i]);
  }
  return decoded;
}

std::string ViewerHTML() {
  return R"(<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Macino</title>
  <style>
    :root { color-scheme: dark; }
    * { box-sizing: border-box; }
    body { margin: 0; min-height: 100vh; background: #111816; color: #f4f7f3; font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    header { display: flex; align-items: center; gap: 12px; padding: 12px 16px; background: #1b2522; border-bottom: 1px solid #34413d; }
    input, button { height: 34px; border-radius: 6px; border: 1px solid #50615c; background: #0f1513; color: #f4f7f3; padding: 0 10px; }
    button { cursor: pointer; background: #0e7c66; border-color: #0e7c66; font-weight: 700; }
    main { min-height: calc(100vh - 59px); display: grid; place-items: center; overflow: auto; }
    img { display: block; max-width: 100vw; max-height: calc(100vh - 59px); width: auto; height: auto; object-fit: contain; }
    .status { margin-left: auto; color: #b8c6c1; font-size: 14px; }
  </style>
</head>
<body>
  <header>
    <strong>Macino</strong>
    <input id="password" type="password" placeholder="Password">
    <button id="connect">Connect</button>
    <span id="status" class="status">Idle</span>
  </header>
  <main><img id="screen" alt="Shared screen"></main>
  <script>
    const img = document.getElementById('screen');
    const status = document.getElementById('status');
    const password = document.getElementById('password');
    const connect = document.getElementById('connect');
    function start() {
      img.src = '/stream?password=' + encodeURIComponent(password.value) + '&t=' + Date.now();
      status.textContent = 'Connected';
    }
    connect.addEventListener('click', start);
    password.addEventListener('keydown', event => { if (event.key === 'Enter') start(); });
    img.addEventListener('error', () => { status.textContent = 'Waiting or unauthorized'; });
    start();
  </script>
</body>
</html>)";
}

}  // namespace

DesktopCaptureService::DesktopCaptureService() {
  Gdiplus::GdiplusStartupInput input;
  Gdiplus::GdiplusStartup(&gdiplus_token_, &input, nullptr);
}

DesktopCaptureService::~DesktopCaptureService() {
  Stop();
  if (gdiplus_token_ != 0) {
    Gdiplus::GdiplusShutdown(gdiplus_token_);
  }
}

bool DesktopCaptureService::Start(std::string* error) {
  if (running_) {
    return true;
  }
  if (gdiplus_token_ == 0) {
    *error = "GDI+ could not be initialized.";
    return false;
  }
  running_ = true;
  worker_ = std::thread(&DesktopCaptureService::CaptureLoop, this);
  return true;
}

void DesktopCaptureService::Stop() {
  running_ = false;
  if (worker_.joinable()) {
    worker_.join();
  }
  std::lock_guard<std::mutex> lock(mutex_);
  latest_jpeg_.clear();
}

bool DesktopCaptureService::IsRunning() const {
  return running_;
}

std::vector<uint8_t> DesktopCaptureService::LatestJPEG() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return latest_jpeg_;
}

void DesktopCaptureService::CaptureLoop() {
  while (running_) {
    std::vector<uint8_t> jpeg;
    std::string error;
    if (CaptureFrame(&jpeg, &error)) {
      std::lock_guard<std::mutex> lock(mutex_);
      latest_jpeg_ = std::move(jpeg);
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(85));
  }
}

bool DesktopCaptureService::CaptureFrame(std::vector<uint8_t>* jpeg,
                                        std::string* error) {
  const int left = GetSystemMetrics(SM_XVIRTUALSCREEN);
  const int top = GetSystemMetrics(SM_YVIRTUALSCREEN);
  const int width = GetSystemMetrics(SM_CXVIRTUALSCREEN);
  const int height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
  if (width <= 0 || height <= 0) {
    *error = "Could not find a display to capture.";
    return false;
  }

  HDC screen_dc = GetDC(nullptr);
  HDC memory_dc = CreateCompatibleDC(screen_dc);
  HBITMAP bitmap = CreateCompatibleBitmap(screen_dc, width, height);
  HGDIOBJ old_bitmap = SelectObject(memory_dc, bitmap);

  const BOOL copied =
      BitBlt(memory_dc, 0, 0, width, height, screen_dc, left, top, SRCCOPY);
  SelectObject(memory_dc, old_bitmap);

  bool ok = false;
  if (copied) {
    Gdiplus::Bitmap image(bitmap, nullptr);
    CLSID encoder;
    if (GetJpegEncoderClsid(&encoder)) {
      IStream* stream = nullptr;
      if (CreateStreamOnHGlobal(nullptr, TRUE, &stream) == S_OK) {
        ULONG quality = 58;
        Gdiplus::EncoderParameters params;
        params.Count = 1;
        params.Parameter[0].Guid = Gdiplus::EncoderQuality;
        params.Parameter[0].Type = Gdiplus::EncoderParameterValueTypeLong;
        params.Parameter[0].NumberOfValues = 1;
        params.Parameter[0].Value = &quality;
        if (image.Save(stream, &encoder, &params) == Gdiplus::Ok) {
          HGLOBAL global = nullptr;
          if (GetHGlobalFromStream(stream, &global) == S_OK) {
            const SIZE_T size = GlobalSize(global);
            void* data = GlobalLock(global);
            if (data && size > 0) {
              auto* bytes = static_cast<uint8_t*>(data);
              jpeg->assign(bytes, bytes + size);
              ok = true;
            }
            if (data) {
              GlobalUnlock(global);
            }
          }
        }
        stream->Release();
      }
    }
  }

  DeleteObject(bitmap);
  DeleteDC(memory_dc);
  ReleaseDC(nullptr, screen_dc);

  if (!ok) {
    *error = LastErrorMessage("Screen capture failed.");
  }
  return ok;
}

LocalMJPEGServer::LocalMJPEGServer(DesktopCaptureService* capture)
    : capture_(capture) {}

LocalMJPEGServer::~LocalMJPEGServer() {
  Stop();
}

bool LocalMJPEGServer::Start(uint16_t port, const std::string& password,
                             std::string* error) {
  if (running_) {
    return true;
  }

  WSADATA wsa_data;
  if (WSAStartup(MAKEWORD(2, 2), &wsa_data) != 0) {
    *error = "Winsock could not be initialized.";
    return false;
  }

  listen_socket_ = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (listen_socket_ == INVALID_SOCKET) {
    *error = "Could not create local server socket.";
    WSACleanup();
    return false;
  }

  BOOL reuse = TRUE;
  setsockopt(listen_socket_, SOL_SOCKET, SO_REUSEADDR,
             reinterpret_cast<const char*>(&reuse), sizeof(reuse));

  sockaddr_in address = {};
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_ANY);
  address.sin_port = htons(port);

  if (bind(listen_socket_, reinterpret_cast<sockaddr*>(&address),
           sizeof(address)) == SOCKET_ERROR ||
      listen(listen_socket_, SOMAXCONN) == SOCKET_ERROR) {
    *error = "Port " + std::to_string(port) + " is not available.";
    closesocket(listen_socket_);
    listen_socket_ = INVALID_SOCKET;
    WSACleanup();
    return false;
  }

  password_ = password;
  port_ = port;
  running_ = true;
  worker_ = std::thread(&LocalMJPEGServer::AcceptLoop, this);
  return true;
}

void LocalMJPEGServer::Stop() {
  running_ = false;
  if (listen_socket_ != INVALID_SOCKET) {
    shutdown(listen_socket_, SD_BOTH);
    closesocket(listen_socket_);
    listen_socket_ = INVALID_SOCKET;
  }
  if (worker_.joinable()) {
    worker_.join();
  }
  WSACleanup();
}

bool LocalMJPEGServer::IsRunning() const {
  return running_;
}

void LocalMJPEGServer::AcceptLoop() {
  while (running_) {
    sockaddr_storage client_address = {};
    int address_length = sizeof(client_address);
    SOCKET client =
        accept(listen_socket_, reinterpret_cast<sockaddr*>(&client_address),
               &address_length);
    if (client == INVALID_SOCKET) {
      if (running_) {
        std::this_thread::sleep_for(std::chrono::milliseconds(30));
      }
      continue;
    }

    if (!IsAllowedPrivateClient(client_address)) {
      closesocket(client);
      continue;
    }
    std::thread(&LocalMJPEGServer::HandleClient, this, client).detach();
  }
}

void LocalMJPEGServer::HandleClient(SOCKET client) {
  char buffer[4096] = {};
  const int received = recv(client, buffer, sizeof(buffer) - 1, 0);
  if (received <= 0) {
    closesocket(client);
    return;
  }

  std::string request(buffer, received);
  const size_t line_end = request.find("\r\n");
  const std::string first_line =
      line_end == std::string::npos ? request : request.substr(0, line_end);
  std::istringstream line(first_line);
  std::string method;
  std::string target;
  line >> method >> target;
  const std::string path = target.substr(0, target.find('?'));

  if (path == "/") {
    SendResponse(client, "200 OK", "text/html; charset=utf-8", ViewerHTML());
  } else if (path == "/stream") {
    if (!IsAuthorized(target)) {
      SendResponse(client, "401 Unauthorized", "text/plain", "Unauthorized");
    } else {
      SendMJPEGStream(client);
    }
  } else {
    SendResponse(client, "404 Not Found", "text/plain", "Not found");
  }
}

void LocalMJPEGServer::SendResponse(SOCKET client, const std::string& status,
                                    const std::string& content_type,
                                    const std::string& body) {
  std::ostringstream headers;
  headers << "HTTP/1.1 " << status << "\r\n"
          << "Content-Type: " << content_type << "\r\n"
          << "Content-Length: " << body.size() << "\r\n"
          << "Cache-Control: no-store\r\n"
          << "Connection: close\r\n\r\n";
  const std::string response = headers.str() + body;
  send(client, response.data(), static_cast<int>(response.size()), 0);
  closesocket(client);
}

void LocalMJPEGServer::SendMJPEGStream(SOCKET client) {
  const std::string headers =
      "HTTP/1.1 200 OK\r\n"
      "Content-Type: multipart/x-mixed-replace; boundary=frame\r\n"
      "Cache-Control: no-store\r\n"
      "Pragma: no-cache\r\n"
      "Connection: close\r\n\r\n";
  send(client, headers.data(), static_cast<int>(headers.size()), 0);

  while (running_) {
    const auto jpeg = capture_->LatestJPEG();
    if (jpeg.empty()) {
      std::this_thread::sleep_for(std::chrono::milliseconds(120));
      continue;
    }

    std::ostringstream part_headers;
    part_headers << "--frame\r\n"
                 << "Content-Type: image/jpeg\r\n"
                 << "Content-Length: " << jpeg.size() << "\r\n\r\n";
    const std::string part = part_headers.str();
    if (send(client, part.data(), static_cast<int>(part.size()), 0) <= 0 ||
        send(client, reinterpret_cast<const char*>(jpeg.data()),
             static_cast<int>(jpeg.size()), 0) <= 0 ||
        send(client, "\r\n", 2, 0) <= 0) {
      break;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(85));
  }
  closesocket(client);
}

bool LocalMJPEGServer::IsAuthorized(const std::string& target) const {
  if (password_.empty()) {
    return true;
  }
  const size_t query_start = target.find('?');
  if (query_start == std::string::npos) {
    return false;
  }

  std::string query = target.substr(query_start + 1);
  std::istringstream stream(query);
  std::string item;
  while (std::getline(stream, item, '&')) {
    const size_t split = item.find('=');
    const std::string key = UrlDecode(item.substr(0, split));
    const std::string value =
        split == std::string::npos ? "" : UrlDecode(item.substr(split + 1));
    if (key == "password" && value == password_) {
      return true;
    }
  }
  return false;
}

bool LocalMJPEGServer::IsAllowedPrivateClient(sockaddr_storage address) const {
  if (address.ss_family == AF_INET) {
    char text[INET_ADDRSTRLEN] = {};
    auto* ipv4 = reinterpret_cast<sockaddr_in*>(&address);
    inet_ntop(AF_INET, &ipv4->sin_addr, text, sizeof(text));
    return IsPrivateIPv4(text);
  }
  if (address.ss_family == AF_INET6) {
    char text[INET6_ADDRSTRLEN] = {};
    auto* ipv6 = reinterpret_cast<sockaddr_in6*>(&address);
    inet_ntop(AF_INET6, &ipv6->sin6_addr, text, sizeof(text));
    return std::string(text) == "::1";
  }
  return false;
}

LocalScreenShareController& LocalScreenShareController::Instance() {
  static LocalScreenShareController instance;
  return instance;
}

LocalScreenShareController::LocalScreenShareController() : server_(&capture_) {}

LocalScreenShareController::~LocalScreenShareController() {
  Stop();
}

void LocalScreenShareController::Register(flutter::BinaryMessenger* messenger,
                                          HWND window) {
  window_ = window;

  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "local_screen_share/native",
      &flutter::StandardMethodCodec::GetInstance());

  channel->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        const std::string method = call.method_name();
        if (method == "getLocalIP") {
          result->Success(flutter::EncodableValue(LocalIPAddress()));
        } else if (method == "getStatus") {
          result->Success(flutter::EncodableValue(
              StatusPayload(IsSharing(), status_message_, ViewerURL())));
        } else if (method == "startSharing") {
          std::string password;
          const auto* args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (args) {
            const auto value = args->find(flutter::EncodableValue("password"));
            if (value != args->end()) {
              if (const auto* text =
                      std::get_if<std::string>(&value->second)) {
                password = *text;
              }
            }
          }
          StartSharing(password);
          if (IsSharing()) {
            result->Success(flutter::EncodableValue(
                StatusPayload(true, status_message_, ViewerURL())));
          } else {
            result->Error("START_FAILED", status_message_);
          }
        } else if (method == "stopSharing") {
          Stop();
          status_message_ = "Stopped";
          result->Success(flutter::EncodableValue(
              StatusPayload(false, status_message_, ViewerURL())));
        } else if (method == "minimizeWindow") {
          MinimizeWindow();
          result->Success();
        } else {
          result->NotImplemented();
        }
      });

  static std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      channel_holder;
  channel_holder = std::move(channel);
}

void LocalScreenShareController::StartSharing(const std::string& password) {
  if (IsSharing()) {
    status_message_ = "Already sharing";
    return;
  }

  std::string error;
  if (!capture_.Start(&error)) {
    status_message_ = error;
    return;
  }
  if (!server_.Start(port_, password, &error)) {
    capture_.Stop();
    status_message_ = error;
    return;
  }
  status_message_ = "Sharing at " + ViewerURL();
}

void LocalScreenShareController::Stop() {
  server_.Stop();
  capture_.Stop();
}

void LocalScreenShareController::MinimizeWindow() const {
  if (window_) {
    ShowWindow(window_, SW_HIDE);
  }
}

bool LocalScreenShareController::IsSharing() const {
  return server_.IsRunning() && capture_.IsRunning();
}

std::string LocalScreenShareController::ViewerURL() const {
  return "http://" + LocalIPAddress() + ":" + std::to_string(port_);
}

std::string LocalScreenShareController::LocalIPAddress() const {
  ULONG flags = GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST |
                GAA_FLAG_SKIP_DNS_SERVER;
  ULONG size = 15 * 1024;
  std::vector<uint8_t> buffer(size);
  auto* adapters = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
  ULONG result = GetAdaptersAddresses(AF_INET, flags, nullptr, adapters, &size);
  if (result == ERROR_BUFFER_OVERFLOW) {
    buffer.resize(size);
    adapters = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
    result = GetAdaptersAddresses(AF_INET, flags, nullptr, adapters, &size);
  }
  if (result != NO_ERROR) {
    return "127.0.0.1";
  }

  for (auto* adapter = adapters; adapter != nullptr; adapter = adapter->Next) {
    if (adapter->OperStatus != IfOperStatusUp ||
        adapter->IfType == IF_TYPE_SOFTWARE_LOOPBACK) {
      continue;
    }
    for (auto* address = adapter->FirstUnicastAddress; address != nullptr;
         address = address->Next) {
      auto* sockaddr = address->Address.lpSockaddr;
      if (!sockaddr || sockaddr->sa_family != AF_INET) {
        continue;
      }
      char text[INET_ADDRSTRLEN] = {};
      auto* ipv4 = reinterpret_cast<sockaddr_in*>(sockaddr);
      inet_ntop(AF_INET, &ipv4->sin_addr, text, sizeof(text));
      if (IsPrivateIPv4(text)) {
        return text;
      }
    }
  }
  return "127.0.0.1";
}
