package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"fmt"
	"os"
)

func main() {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		fail(err)
	}

	privDER, err := x509.MarshalPKCS8PrivateKey(priv)
	if err != nil {
		fail(err)
	}
	pubDER, err := x509.MarshalPKIXPublicKey(pub)
	if err != nil {
		fail(err)
	}

	fmt.Printf("JWT_PRIVATE_KEY=%s\n", encode("PRIVATE KEY", privDER))
	fmt.Println()
	fmt.Printf("JWT_PUBLIC_KEY=%s\n", encode("PUBLIC KEY", pubDER))
}

func encode(blockType string, der []byte) string {
	p := pem.EncodeToMemory(&pem.Block{Type: blockType, Bytes: der})
	return base64.StdEncoding.EncodeToString(p)
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, "genkeys:", err)
	os.Exit(1)
}
