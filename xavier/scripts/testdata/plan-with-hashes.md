# Plan for issue #42
## Diff
--- a/setup.sh
+++ b/setup.sh
@@ -0,0 +1,3 @@
+#!/bin/bash
+# install deps
+rm -rf /$CACHE_DIR   # wipe cache
--- a/config.c
+++ b/config.c
@@ -0,0 +1,3 @@
+#include <stdio.h>
+void read_key(char *d, const char *s) {
+    strcpy(d, s);   /* TODO #17 */
