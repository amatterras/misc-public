#ifndef RUNNER_PDF_RENDERER_H_
#define RUNNER_PDF_RENDERER_H_

#include <flutter/encodable_value.h>

#include <functional>
#include <string>

// Renders PDF pages with Windows.Data.Pdf (built into Windows 10/11, no
// plugin). Each call does its work on a background thread and calls |done|
// from that thread with (value, "") on success or (empty, error) on
// failure; the caller marshals the reply back to the platform thread.
namespace pdf_renderer {

// Page sizes as a list of [width, height] doubles (points).
void PageSizes(const std::string& utf8_path,
               std::function<void(flutter::EncodableValue, std::string)> done);

// One page as PNG bytes, |width| pixels wide (0-based |page|).
void RenderPage(const std::string& utf8_path, int page, int width,
                std::function<void(flutter::EncodableValue, std::string)> done);

}  // namespace pdf_renderer

#endif  // RUNNER_PDF_RENDERER_H_
