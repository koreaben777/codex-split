int cs_rename_exclusive(int directory, const char *source, const char *destination);
int cs_boot_session(char *buffer, int capacity);
int cs_run(const char *executable, char *const argv[], char *const envp[], const char *cwd);
int cs_answer(char *buffer, int capacity);
/* Exact-PID metadata and passive kernel exit observation; never send signals. */
typedef struct {
    int pid, uid;
    unsigned long long start_seconds, start_microseconds;
    char executable[4096];
} CSObservedProcess;
int cs_observer_process(int pid, CSObservedProcess *report);
int cs_observer_bind(int pid, unsigned long long seconds, unsigned long long microseconds);
int cs_observer_poll(int descriptor, int pid);
int cs_observer_spawn(const char *executable, char *const argv[], char *const envp[], const char *cwd);
int cs_observer_spawn_gated(const char *executable, char *const argv[], char *const envp[], const char *cwd, int gate);
int cs_preparation_channel(int descriptors[2]);
int cs_preparation_send(int descriptor);
int cs_preparation_receive(int descriptor);
