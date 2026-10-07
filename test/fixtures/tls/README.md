# TLS test fixtures

A throwaway self-signed CA and a `localhost` leaf it signed, used only by
`test/unit/capture/http_seam_test.dart` to stand up a loopback HTTPS server and
assert that certificate pinning still works once HTTP capture installs its
connection factory.

`localhost_key.pem` **is a private key, and it is meant to be public.** It was
generated for this repository, it signs nothing but `localhost`, and it never
leaves the test suite. Regenerate with:

```sh
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca_key.pem -out ca_cert.pem \
  -days 3650 -subj "/CN=edge_telemetry test CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign"
openssl req -newkey rsa:2048 -nodes -keyout localhost_key.pem -out server.csr \
  -subj "/CN=localhost"
openssl x509 -req -in server.csr -CA ca_cert.pem -CAkey ca_key.pem \
  -CAcreateserial -out localhost_cert.pem -days 3650 \
  -extfile <(printf "subjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\nkeyUsage=critical,digitalSignature,keyEncipherment\n")
rm server.csr ca_cert.srl ca_key.pem
```

The CA key is deliberately **not** kept — nothing ever needs to sign a second
certificate, and regenerating both is one command.
