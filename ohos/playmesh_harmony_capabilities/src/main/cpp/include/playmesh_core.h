#ifndef PLAYMESH_CORE_H
#define PLAYMESH_CORE_H

#ifdef __cplusplus
extern "C" {
#endif

int PlaymeshCoreStart(
    const char* address,
    char** bound_address,
    char** error_message);
int PlaymeshCoreStop(char** error_message);
void PlaymeshCoreFree(char* value);

#ifdef __cplusplus
}
#endif

#endif
