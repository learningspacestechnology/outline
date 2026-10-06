FROM node:20-slim

WORKDIR /opt/outline

# Install build dependencies
RUN apt-get update && \
    apt-get install -y python3 build-essential wget && \
    rm -rf /var/lib/apt/lists/*

# Use the Yarn version pinned in package.json's "packageManager" field (Yarn 4
# via Corepack); the node image ships classic Yarn 1.x which refuses to run.
ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0
RUN corepack enable

# Copy package files first for better caching
COPY package.json yarn.lock .yarnrc.yml ./
RUN yarn install

# Limit glibc malloc arenas, which default to 8 per CPU. Each arena can hold
# onto 64MB of virtual memory and freed allocations, which inflates resident
# memory in multi-threaded Node.js processes for no performance benefit here.
ENV MALLOC_ARENA_MAX=2

# Create a non-root user compatible with Debian and BusyBox based images
ENV APP_PATH=/opt/outline
RUN addgroup --gid 1001 nodejs && \
    adduser --uid 1001 --ingroup nodejs nodejs && \
    mkdir -p /var/lib/outline && \
    chown -R nodejs:nodejs /var/lib/outline && \
    chown -R nodejs:nodejs $APP_PATH

# Copy the rest of the application
COPY . .

# Build the application
RUN yarn build

# Create directories for data storage
RUN mkdir -p /var/lib/outline/data && \
    chmod 1777 /var/lib/outline/data

VOLUME /var/lib/outline/data

HEALTHCHECK --interval=1m CMD wget -qO- "http://localhost:${PORT:-3000}/_health" | grep -q "OK" || exit 1

EXPOSE 3000
CMD ["yarn", "start"]
