# sagefs.nvim E2E test container
# Includes: .NET 10, SageFs, Neovim, Lua/busted, curl
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS base

# Install system deps
RUN apt-get update && apt-get install -y --no-install-recommends \
  curl git unzip luarocks lua5.1 liblua5.1-dev ca-certificates \
  && rm -rf /var/lib/apt/lists/*

# Install Neovim (stable AppImage → extract)
RUN curl -fsSL https://github.com/neovim/neovim/releases/download/stable/nvim-linux-x86_64.tar.gz \
  | tar xz -C /opt \
  && ln -s /opt/nvim-linux-x86_64/bin/nvim /usr/local/bin/nvim

# Install Lua test deps
RUN luarocks install busted && luarocks install dkjson

# Install SageFs global tool
RUN dotnet tool install --global SageFs
ENV PATH="$PATH:/root/.dotnet/tools"

# Copy plugin source
WORKDIR /plugin
COPY . .

# Pre-build sample projects
RUN for d in samples/Minimal samples/WithTests samples/MultiFile; do \
  if [ -d "$d" ]; then dotnet build "$d" --nologo -v q; fi; \
  done

# Default: run unit + integration tests
CMD ["bash", "-c", "busted && nvim --headless --clean -u NONE -l spec/nvim_harness.lua"]
