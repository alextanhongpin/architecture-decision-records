# Webhook

https://aps.autodesk.com/en/docs/webhooks/v1/tutorials/how-to-verify-payload-signature/



```go
package main

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
)

func main() {
	// create a random 64 bytes (512 bits) secret
	secret, err := NewSecret(64)
	if err != nil {
		panic(err)
	}

	data := []byte("Hello World")

	// create a new HMAC by defining the hash type and the key
	dataHmac := NewSignature(secret, data)

	hmacHex := hex.EncodeToString(dataHmac)
	secretHex := hex.EncodeToString(secret)

	fmt.Printf("HMAC_SHA256(key: %s, data: %s): %s\n", secretHex, string(data), hmacHex)
	// Multiple secrets can be passed in case of rotation.
	fmt.Println(Verify([]string{secretHex}, data, hmacHex))
}

func Verify(secrets []string, data []byte, signature string) (bool, error) {
	for _, sec := range secrets {
		b, err := hex.DecodeString(sec)
		if err != nil {
			return false, err
		}
		if hex.EncodeToString(NewSignature(b, data)) == signature {
			return true, nil
		}
	}

	return false, nil
}

func NewSignature(secret, data []byte) []byte {
	// create a new HMAC by defining the hash type and the key
	hmac := hmac.New(sha256.New, secret)

	// compute the HMAC
	hmac.Write([]byte(data))
	return hmac.Sum(nil)
}

func NewSecret(size int) ([]byte, error) {
	secret := make([]byte, size)
	_, err := rand.Read(secret)
	if err != nil {
		return nil, err
	}
	return secret, nil
}
```
