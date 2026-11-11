#include "pdf_renderer.h"

#include <windows.h>

#include <winrt/base.h>
#include <winrt/Windows.Data.Pdf.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Imaging.h>
#include <winrt/Windows.Storage.Streams.h>

#include <cstdint>
#include <fstream>
#include <stdexcept>
#include <thread>
#include <utility>
#include <vector>

namespace pdf_renderer {
namespace {

using winrt::Windows::Data::Pdf::PdfDocument;
using winrt::Windows::Data::Pdf::PdfPageRenderOptions;
using winrt::Windows::Storage::Streams::DataReader;
using winrt::Windows::Storage::Streams::DataWriter;
using winrt::Windows::Storage::Streams::InMemoryRandomAccessStream;

std::wstring Widen(const std::string& utf8) {
  if (utf8.empty()) return std::wstring();
  int length = MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                   static_cast<int>(utf8.size()), nullptr, 0);
  if (length <= 0) return std::wstring();
  std::wstring wide(static_cast<size_t>(length), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                      wide.data(), length);
  return wide;
}

// Loads the file into an in-memory stream (no StorageFile broker), so any
// readable path works, including the app's temporary view copies.
PdfDocument LoadDocument(const std::string& utf8_path) {
  std::ifstream file(Widen(utf8_path).c_str(), std::ios::binary);
  if (!file) throw std::runtime_error("unreadable");
  std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(file)),
                             std::istreambuf_iterator<char>());
  InMemoryRandomAccessStream stream;
  DataWriter writer(stream.GetOutputStreamAt(0));
  writer.WriteBytes(bytes);
  writer.StoreAsync().get();
  writer.FlushAsync().get();
  writer.DetachStream();
  return PdfDocument::LoadFromStreamAsync(stream).get();
}

// Blocking WinRT waits are fine here: every job runs on its own MTA
// worker thread, never on the platform (STA) thread.
void RunOnWorker(std::function<void()> work) {
  std::thread([work = std::move(work)]() {
    winrt::init_apartment(winrt::apartment_type::multi_threaded);
    work();
  }).detach();
}

}  // namespace

void PageSizes(
    const std::string& utf8_path,
    std::function<void(flutter::EncodableValue, std::string)> done) {
  RunOnWorker([utf8_path, done = std::move(done)]() {
    try {
      auto doc = LoadDocument(utf8_path);
      flutter::EncodableList pages;
      for (uint32_t i = 0; i < doc.PageCount(); i++) {
        auto size = doc.GetPage(i).Size();
        pages.push_back(flutter::EncodableValue(flutter::EncodableList{
            flutter::EncodableValue(static_cast<double>(size.Width)),
            flutter::EncodableValue(static_cast<double>(size.Height))}));
      }
      done(flutter::EncodableValue(std::move(pages)), "");
    } catch (...) {
      done(flutter::EncodableValue(), "The PDF could not be read.");
    }
  });
}

void RenderPage(
    const std::string& utf8_path, int page, int width,
    std::function<void(flutter::EncodableValue, std::string)> done) {
  RunOnWorker([utf8_path, page, width, done = std::move(done)]() {
    try {
      auto doc = LoadDocument(utf8_path);
      if (page < 0 || static_cast<uint32_t>(page) >= doc.PageCount()) {
        throw std::out_of_range("page");
      }
      auto pdf_page = doc.GetPage(static_cast<uint32_t>(page));
      auto size = pdf_page.Size();
      uint32_t w = static_cast<uint32_t>(width < 16      ? 16
                                         : width > 4096 ? 4096
                                                        : width);
      PdfPageRenderOptions options;
      options.DestinationWidth(w);
      if (size.Width > 0) {
        options.DestinationHeight(
            static_cast<uint32_t>(w * size.Height / size.Width + 0.5f));
      }
      options.BitmapEncoderId(
          winrt::Windows::Graphics::Imaging::BitmapEncoder::PngEncoderId());
      InMemoryRandomAccessStream out;
      pdf_page.RenderToStreamAsync(out, options).get();
      uint32_t length = static_cast<uint32_t>(out.Size());
      DataReader reader(out.GetInputStreamAt(0));
      reader.LoadAsync(length).get();
      std::vector<uint8_t> bytes(length);
      reader.ReadBytes(bytes);
      done(flutter::EncodableValue(std::move(bytes)), "");
    } catch (...) {
      done(flutter::EncodableValue(), "The PDF page could not be rendered.");
    }
  });
}

}  // namespace pdf_renderer
