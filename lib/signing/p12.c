// PKCS#12 assembly with OpenSSL: certificate + private key (DER or PEM) -> .p12.
#include <openssl/pkcs12.h>
#include <openssl/x509.h>
#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/bio.h>
#include <stdlib.h>
#include <string.h>

// Returns 0 and a malloc'ed buffer in *out on success.
int ferry_make_p12(const unsigned char *cert_der, size_t cert_len,
                   const unsigned char *key_der, size_t key_len,
                   const char *password, const char *name,
                   unsigned char **out, size_t *out_len)
{
	// Each input may be DER or PEM.
	const unsigned char *p = cert_der;
	X509 *cert = d2i_X509(NULL, &p, (long)cert_len);
	if (!cert) {
		BIO *b = BIO_new_mem_buf(cert_der, (int)cert_len);
		cert = PEM_read_bio_X509(b, NULL, NULL, NULL);
		BIO_free(b);
	}
	if (!cert) return 1;
	p = key_der;
	EVP_PKEY *key = d2i_AutoPrivateKey(NULL, &p, (long)key_len);
	if (!key) {
		BIO *b = BIO_new_mem_buf(key_der, (int)key_len);
		key = PEM_read_bio_PrivateKey(b, NULL, NULL, NULL);
		BIO_free(b);
	}
	if (!key) { X509_free(cert); return 2; }
	if (X509_check_private_key(cert, key) != 1) { EVP_PKEY_free(key); X509_free(cert); return 3; }

	PKCS12 *p12 = PKCS12_create(password, name, key, cert, NULL, 0, 0, 0, 0, 0);
	EVP_PKEY_free(key);
	X509_free(cert);
	if (!p12) return 4;

	unsigned char *buf = NULL;
	int len = i2d_PKCS12(p12, &buf);
	PKCS12_free(p12);
	if (len <= 0) return 5;
	*out = malloc((size_t)len);
	if (!*out) { OPENSSL_free(buf); return 6; }
	memcpy(*out, buf, (size_t)len);
	*out_len = (size_t)len;
	OPENSSL_free(buf);
	return 0;
}
