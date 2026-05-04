import Foundation

public enum SampleProfiles {
    public static let starter = """
    [General]
    loglevel = notify
    http-listen = 127.0.0.1:6152
    socks5-listen = 127.0.0.1:6153

    [Proxy]
    Local HTTP = http, 127.0.0.1, 8080
    Demo SOCKS = socks5, 127.0.0.1, 1080
    Demo SS = ss, example.com, 8388, aes-128-gcm, password, udp-relay=true

    [Proxy Group]
    Auto = url-test, Local HTTP, Demo SOCKS, url=http://www.gstatic.com/generate_204, interval=300
    Select = select, Auto, Local HTTP, Demo SOCKS, DIRECT

    [Rule]
    DOMAIN-SUFFIX, apple.com, DIRECT
    DOMAIN-KEYWORD, example, Select
    DOMAIN-WILDCARD, *.internal.test, DIRECT
    URL-REGEX, ^https://api\\.regex\\.test/v[0-9]+/, Select
    IP-CIDR, 10.0.0.0/8, DIRECT
    IP-CIDR6, fc00::/7, DIRECT
    DEST-PORT, 8443;9000-9002, Select
    FINAL, Select
    """
}
