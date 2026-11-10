/// Sets an environment variable in this process through libc. There is no libc in a browser.
void libcSetenv(String name, String value) => throw UnsupportedError('web: libcSetenv');
