/*
 * pearl-guard.c — Ultra-fast native macOS guardrail validator (< 0.8ms)
 * Protects MacBook Neo against catastrophic, destructive, or unauthorized operations
 * while permitting full developer freedom in /Users/rossonerian.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <regex.h>

typedef struct {
    const char *pattern;
    const char *code;
    const char *reason;
} GuardRule;

static const GuardRule RULES[] = {
    // 1. Privilege Escalation
    {"(^|[;&|`[:space:]]+)(sudo|su|doas)([[:space:]]+|$)", 
     "E_PRIV_ESC", 
     "Privilege escalation (sudo/su/doas) is permanently blocked."},

    // 2. Catastrophic Filesystem Deletions
    {"(^|[;&|`[:space:]]+)rm([[:space:]]+-[a-zA-Z0-9]*[rfRF][a-zA-Z0-9]*)*[[:space:]]+(/|~|\\$HOME|\\$\\{HOME\\}|/Users/rossonerian)(/|/\\*|\\*|[[:space:]]+|$)", 
     "E_CATASTROPHIC_RM", 
     "Destructive recursive deletion of system or user root is blocked."},

    {"(^|[;&|`[:space:]]+)rm([[:space:]]+-[a-zA-Z0-9]*[rfRF][a-zA-Z0-9]*)*[[:space:]]+(/System|/Library|/Applications|/usr|/bin|/sbin|/private|/etc|/var)", 
     "E_SYSTEM_RM", 
     "Deletion of macOS system directories is blocked."},

    // 3. Destructive Disk & Volume Formatting
    {"(^|[;&|`[:space:]]+)diskutil[[:space:]]+(eraseDisk|partitionDisk|eraseVolume|unmountDisk|apfs[[:space:]]+deleteVolume)", 
     "E_DISK_FORMAT", 
     "Destructive disk and volume formatting is permanently blocked."},

    {"(^|[;&|`[:space:]]+)dd[[:space:]]+if=.*of=/dev/", 
     "E_RAW_DISK_WRITE", 
     "Raw block device writing with dd is blocked."},

    {"(^|[;&|`[:space:]]+)(mkfs|newfs_)", 
     "E_NEWFS", 
     "Filesystem formatting commands are blocked."},

    // 4. System Integrity, NVRAM & Kernel Extensions
    {"(^|[;&|`[:space:]]+)(csrutil|nvram|kextunload|kextload|kmutil|spctl[[:space:]]+--master-disable)", 
     "E_SYS_INTEGRITY", 
     "Altering System Integrity Protection, NVRAM, or kernel extensions is blocked."},

    {"(^|[;&|`[:space:]]+)networksetup[[:space:]]+-set(webproxy|securewebproxy|socksfirewallproxy)", 
     "E_PROXY_TAMPER", 
     "Modifying system network proxy settings is blocked."},

    {"(^|[;&|`[:space:]]+)pfctl[[:space:]]+-[dF]", 
     "E_FIREWALL_TAMPER", 
     "Disabling or flushing the packet filter firewall is blocked."},

    // 5. Credential, Private Key & Keychain Exfiltration
    {"(~|\\$HOME|/Users/rossonerian)/\\.(ssh|gnupg|claude\\.json|zeroclaw/\\.secret_key)", 
     "E_SECRET_ACCESS", 
     "Direct access to private SSH keys, GPG keys, or API tokens is blocked."},

    {"security[[:space:]]+(dump-keychain|find-generic-password|find-internet-password|export)", 
     "E_KEYCHAIN_ACCESS", 
     "Dumping or exporting macOS keychain passwords is blocked."},

    // 6. Dangerous AppleScript & GUI Injection
    {"osascript.*with[[:space:]]+administrator[[:space:]]+privileges", 
     "E_APPLESCRIPT_ADMIN", 
     "AppleScript administrator privilege escalation is blocked."},

    {"osascript.*System[[:space:]]+Events.*(keystroke|key[[:space:]]+code)", 
     "E_UI_KEYSTROKE_INJECTION", 
     "Synthetic GUI keystroke injection via AppleScript is blocked."},

    {"osascript.*Finder.*empty[[:space:]]+trash", 
     "E_TRASH_WIPE", 
     "Permanent trash deletion via AppleScript is blocked."},

    // 7. Malicious Persistence
    {"(^|[;&|`[:space:]]+)launchctl[[:space:]]+(load|submit)", 
     "E_LAUNCHD_PERSISTENCE", 
     "Registering unvetted background daemons is blocked."},

    {"(^|[;&|`[:space:]]+)crontab[[:space:]]+-[eir]", 
     "E_CRONTAB_TAMPER", 
     "Editing or removing cron schedules is blocked."},

    {NULL, NULL, NULL}
};

int main(int argc, char **argv) {
    if (argc < 2) {
        return 0; // Empty input is allowed
    }

    const char *cmd = argv[1];

    for (int i = 0; RULES[i].pattern != NULL; i++) {
        regex_t reg;
        if (regcomp(&reg, RULES[i].pattern, REG_EXTENDED | REG_NOSUB | REG_ICASE) == 0) {
            int match = regexec(&reg, cmd, 0, NULL, 0);
            regfree(&reg);
            if (match == 0) {
                fprintf(stderr, "{\"status\":\"BLOCKED\",\"code\":\"%s\",\"reason\":\"%s\"}\n",
                        RULES[i].code, RULES[i].reason);
                return 1; // BLOCKED
            }
        }
    }

    return 0; // ALLOWED
}
