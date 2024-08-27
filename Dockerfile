ARG GLEAM_VERSION=v1.4.1

FROM ghcr.io/gleam-lang/gleam:${GLEAM_VERSION}-erlang-alpine AS builder

# Add project code
COPY ./common /build/common
COPY ./client /build/client
COPY ./server /build/server

# Compile the client code
RUN cd /build/client \
  && gleam clean  && gleam run -m lustre/dev build app --outdir=/build/server/priv/static

# Compile the server code
RUN cd /build/server \
  && gleam export erlang-shipment

# Start from a clean slate
FROM ghcr.io/gleam-lang/gleam:${GLEAM_VERSION}-erlang-alpine

# Copy the compiled server code from the builder stage
COPY --from=builder /build/server/build/erlang-shipment /app

# Run the server
WORKDIR /app
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["run"]
