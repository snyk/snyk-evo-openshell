Optional. If your network does TLS inspection (Zscaler etc.), put the root CA here as a PEM `.crt` before `docker build`:

    security find-certificate -a -c "Zscaler Root CA" -p /Library/Keychains/System.keychain > corp-ca/zscaler.crt

`*.crt` files are gitignored. Note: this only fixes the image build. OpenShell's supervisor makes the real outbound connections and does not trust this cert, so the sandbox itself still needs TLS inspection off (see README, Known issues).
