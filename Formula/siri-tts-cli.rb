class SiriTtsCli < Formula
  desc "Render installed neural Siri voices from the macOS command-line"
  homepage "https://github.com/maximilianromer/siri-tts-cli"
  url "https://github.com/maximilianromer/siri-tts-cli.git", tag: "v2.0.0"
  license "MIT"
  head "https://github.com/maximilianromer/siri-tts-cli.git", branch: "main"

  depends_on xcode: ["26.0", :build]
  depends_on :macos

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"
    system "codesign", "--force", "--sign", "-", ".build/release/siri-tts"
    bin.install ".build/release/siri-tts"
  end

  test do
    assert_match "siri-tts", shell_output("#{bin}/siri-tts --help")
    assert_match "siri-tts doctor", shell_output("#{bin}/siri-tts doctor --skip-probe")
  end
end
