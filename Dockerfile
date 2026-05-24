# Use the requested GraalVM Native Image base from Oracle Container Registry
FROM container-registry.oracle.com/graalvm/native-image:25

# 1. Install system packages (git, curl, etc.) and Fish shell
# Note: epel-release is installed first to make the 'fish' package available.
RUN microdnf install -y git curl tar gzip findutils which epel-release \
    && microdnf install -y fish \
    && microdnf clean all

# 2. Install Babashka (via official installer)
RUN curl -s https://raw.githubusercontent.com/babashka/babashka/master/install | bash

# 3. Install Clojure CLI (latest stable release)
RUN curl -L -O https://github.com/clojure/brew-install/releases/latest/download/linux-install.sh \
    && chmod +x linux-install.sh \
    && ./linux-install.sh \
    && rm linux-install.sh

# 4. Install Leiningen
# Downloads the script, makes it executable, and runs it once to download the self-install jar.
RUN curl https://raw.githubusercontent.com/technomancy/leiningen/stable/bin/lein > /usr/local/bin/lein \
    && chmod +x /usr/local/bin/lein \
    && export LEIN_ROOT=1 \
    && lein version

# 5. Install Zig (Version 0.16.0 - estimated current stable for May 2026)
ARG ZIG_VERSION=0.16.0
RUN curl -L "https://ziglang.org{ZIG_VERSION}/zig-linux-x86_64-${ZIG_VERSION}.tar.xz" | tar -xJ -C /usr/local \
    && ln -s "/usr/local/zig-linux-x86_64-${ZIG_VERSION}/zig" /usr/local/bin/zig

# 6. Set GRAALVM_HOME for Bash and Fish
# We inherit JAVA_HOME from the base image. We set GRAALVM_HOME to match it.

# For Bash (and global environment):
ENV GRAALVM_HOME=$JAVA_HOME

# For Fish (created as a config file in conf.d):
RUN mkdir -p /etc/fish/conf.d \
    && echo "set -gx GRAALVM_HOME $JAVA_HOME" > /etc/fish/conf.d/graalvm.fish

# Default command
CMD ["fish"]

