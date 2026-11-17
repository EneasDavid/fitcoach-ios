import Foundation

/// Self-signed certificates for `api.fitcoach.test` (valid 2026-11-15 → 2027-09-11) plus their SPKI pins as
/// computed by **OpenSSL**, independently of our code:
///
///     openssl x509 -in cert.pem -pubkey -noout | openssl pkey -pubin -outform der \
///       | openssl dgst -sha256 -binary | base64
///
/// Trust evaluation in the tests pins the verification date inside the validity window, so these
/// fixtures never turn into a time bomb.
enum PinningFixtures {
    static let host = "api.fitcoach.test"
    static let verificationDate = Date(timeIntervalSince1970: 1_796_083_200)   // 2026-12-01

    static let ecCertificateDER = Data(base64Encoded: """
    MIIBwDCCAWWgAwIBAgIUB/O3PMvw65Le4d3awCoCgZKO/Q4wCgYIKoZIzj0EAwIwHDEaMBgGA1UEAwwRYXBpLmZpdGNvYWNoLnRlc3QwHhcNMjYxMTE1MTU0NDI3WhcNMjcwOTExMTU0NDI3WjAcMRowGAYDVQQDDBFhcGkuZml0Y29hY2gudGVzdDBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABJfWBm68uAyNEexBDuNMYMlBrl7TVQ0XF3vqgXraxG+h61TjFkEUwkwA8xw0BdZFeQvYJHkUGiVUJOLIv2XbV/2jgYQwgYEwHQYDVR0OBBYEFDFkAeNGgCgq8V8c8hRbOD1HCp98MB8GA1UdIwQYMBaAFDFkAeNGgCgq8V8c8hRbOD1HCp98MBwGA1UdEQQVMBOCEWFwaS5maXRjb2FjaC50ZXN0MBMGA1UdJQQMMAoGCCsGAQUFBwMBMAwGA1UdEwEB/wQCMAAwCgYIKoZIzj0EAwIDSQAwRgIhAJd5sm31Qsg+C8ri/YKG7reoL1hIZ4J5B2Orv+vNj6UwAiEAwzXocM4Dpi+LCh3aTCd4wiMG9Ufgwfokl6RGBMmJZEo=
    """)!
    static let ecPin = "1PzBIQQu8Ehfdw3VmRuJ3wuWE57hKgSNAtmRn3XNodE="

    static let rsaCertificateDER = Data(base64Encoded: """
    MIIDSzCCAjOgAwIBAgIUHf/Kb8+Q7t8JDM+gkKnsv1imHWYwDQYJKoZIhvcNAQELBQAwHDEaMBgGA1UEAwwRYXBpLmZpdGNvYWNoLnRlc3QwHhcNMjYxMTE1MTU0NDIzWhcNMjcwOTExMTU0NDIzWjAcMRowGAYDVQQDDBFhcGkuZml0Y29hY2gudGVzdDCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAMP0rw9E17dI3IyecU5TpPMoTcnZBmM/g7X1/8DYjMTNYBOTaD5qcOgvYSsD2pc5ZIA+rmZQc6rxQ4zN2maV4x5wL9KVdNWmkZrC4uOeFEW1cxOu01a7cKm6+AKJNO0syKxJ2ycjGQoRXuJdJNhFHfbRm2FA9EYjyQy64BBI7a46VfOe+vABFdJuqRwGX/fbA26tG+/SmIu9ZbgHQeKy0nDVUAgEyPV7/0RdkYh/z1zdtIDS0xa085cJdIl/8nFXE9eR7LvToZ8KN3pSQrU7toNjDL+cvVww9xuDmTjY3YQ4G4H8Auo4vIRm49CRAnl+WbZ57TG1NLL8E8YSIltK6xUCAwEAAaOBhDCBgTAdBgNVHQ4EFgQU6OeU6rsXWlrLADXu35UeLqJ73yQwHwYDVR0jBBgwFoAU6OeU6rsXWlrLADXu35UeLqJ73yQwHAYDVR0RBBUwE4IRYXBpLmZpdGNvYWNoLnRlc3QwEwYDVR0lBAwwCgYIKwYBBQUHAwEwDAYDVR0TAQH/BAIwADANBgkqhkiG9w0BAQsFAAOCAQEASL+u1cOR9f6lzu4tOaFyr03gt1etrZCJ/ld4ouOut0Abye8AtB+V6MeZ+IbG6ywSLnQ1Lblf7dnot12wMF4FRl5cGxx95IYYrgqt1ryf0c/H73Cgyj4P753nBVuxR5aWZL8FStm8dUAWniDuV5WdxDuf0RRLRO1AhV1KK9HEGJjK6zeI3x1Niy3YLv54iagPFnpaBT/GqSD5AlOIMcs9mma4LigRrxD+BnJE8vFRsVOwVCH6/LMRmzjZhxIWNo1+10lEJPxr11ADPfooFApH8N6eSVPaW/WwOoLr3K2+0O3nUElqOk2XziXJWmbgINYmnntFkseFodyCq2QoUMnh0Q==
    """)!
    static let rsaPin = "6vnhLZwCq16W8jrBPUX1agb6+tWe9boJJ7qLADtKoFE="
}
