import Foundation
import PolishCore
import Testing

@Suite struct WebsiteSourceTests {
    @Test func keepsOnlyTheHostAndDoesNotGuessWebsiteIdentity() throws {
        let url = try #require(URL(string: "https://user:secret@MAIL.Google.COM.:443/mail/u/2?token=private#draft"))
        #expect(WebsiteSource(url: url)?.host == "mail.google.com")
        #expect(WebsiteSource(url: URL(string: "https://chatgpt.com.attacker.example/")!)?.host == "chatgpt.com.attacker.example")
        #expect(WebsiteSource(url: URL(string: "https://例子.测试/draft")!)?.host == "xn--fsqu00a.xn--0zwm56d")
        #expect(WebsiteSource(url: URL(string: "http://[::1]:8080/draft")!)?.host == "::1")
        #expect(WebsiteSource(url: URL(string: "http://localhost:8080/draft")!)?.host == "localhost")
    }

    @Test func rejectsNonWebPagesAndInvalidPersistedHosts() {
        for text in ["file:///tmp/private.html", "chrome://settings", "about:blank", "app://-/index.html"] {
            #expect(WebsiteSource(url: URL(string: text)!) == nil)
        }
        for text in ["", "https://example.com", "user@example.com", "example.com/path", "example.com?token=secret",
                     "example.com#draft", "example.com:8080", "example.com\n", "example.com%2Fprivate"] {
            #expect(WebsiteSource(host: text) == nil)
        }
    }
}
