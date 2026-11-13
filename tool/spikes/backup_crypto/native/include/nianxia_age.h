#ifndef NIANXIA_AGE_H
#define NIANXIA_AGE_H
#include <stddef.h>
#include <stdint.h>
/* Test-only ABI. Paths/password are counted UTF-8 bytes, copied on create.
 * Password: 1..4096 bytes, never trimmed/normalized. No paths or secrets in codes.
 * run blocks: call on worker; cancel only requests cancellation.
 * free is legal only AFTER run returns; returns 6 while running/borrowed.
 * 0=success, 1=authentication,2=resource,3=container,4=cancelled,5=IO,6=busy.
 */
void *nx_age_alloc(size_t length);
void nx_age_release(uint8_t *pointer,size_t length);
uint64_t nx_age_create(const uint8_t *input,size_t input_len,const uint8_t *output,size_t output_len,const uint8_t *password,size_t password_len,uint8_t encrypt,uint8_t write_log_n,uint8_t max_read_log_n,size_t max_header_bytes);
int32_t nx_age_run(uint64_t operation);
void nx_age_cancel(uint64_t operation);
int32_t nx_age_free(uint64_t operation);
uint64_t nx_age_bytes(uint64_t operation);
uint64_t nx_age_kdf_started(uint64_t operation);
uint64_t nx_age_stage(uint64_t operation);
#endif
