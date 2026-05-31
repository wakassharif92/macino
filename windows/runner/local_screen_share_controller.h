#ifndef RUNNER_LOCAL_SCREEN_SHARE_CONTROLLER_H_
#define RUNNER_LOCAL_SCREEN_SHARE_CONTROLLER_H_

#include <flutter/binary_messenger.h>

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#ifndef NOMINMAX
#define NOMINMAX
#endif

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <winsock2.h>
#include <windows.h>

class DesktopCaptureService {
 public:
  DesktopCaptureService();
  ~DesktopCaptureService();

  bool Start(std::string* error);
  void Stop();
  bool IsRunning() const;
  std::vector<uint8_t> LatestJPEG() const;

 private:
  void CaptureLoop();
  bool CaptureFrame(std::vector<uint8_t>* jpeg, std::string* error);

  mutable std::mutex mutex_;
  std::vector<uint8_t> latest_jpeg_;
  std::atomic<bool> running_{false};
  std::thread worker_;
  ULONG_PTR gdiplus_token_ = 0;
};

class LocalMJPEGServer {
 public:
  explicit LocalMJPEGServer(DesktopCaptureService* capture);
  ~LocalMJPEGServer();

  bool Start(uint16_t port, const std::string& password, std::string* error);
  void Stop();
  bool IsRunning() const;

 private:
  void AcceptLoop();
  void HandleClient(SOCKET client);
  void SendResponse(SOCKET client, const std::string& status,
                    const std::string& content_type, const std::string& body);
  void SendMJPEGStream(SOCKET client);
  bool IsAuthorized(const std::string& target) const;
  bool IsAllowedPrivateClient(sockaddr_storage address) const;

  DesktopCaptureService* capture_;
  std::string password_;
  uint16_t port_ = 41873;
  std::atomic<bool> running_{false};
  SOCKET listen_socket_ = INVALID_SOCKET;
  std::thread worker_;
};

class LocalScreenShareController {
 public:
  static LocalScreenShareController& Instance();

  void Register(flutter::BinaryMessenger* messenger, HWND window);
  void Stop();

 private:
  LocalScreenShareController();
  ~LocalScreenShareController();

  void StartSharing(const std::string& password);
  void MinimizeWindow() const;
  std::string LocalIPAddress() const;
  std::string ViewerURL() const;
  bool IsSharing() const;

  HWND window_ = nullptr;
  DesktopCaptureService capture_;
  LocalMJPEGServer server_;
  std::string status_message_ = "Ready";
  const uint16_t port_ = 41873;
};

#endif  // RUNNER_LOCAL_SCREEN_SHARE_CONTROLLER_H_
