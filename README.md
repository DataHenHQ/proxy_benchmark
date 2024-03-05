# Proxy benchmark

This script was designed to benchmark a list of proxies to provide MAX, MIN and AVERAGE times. If no proxy list is provided then it will perform the benchmark using your computer's IP address.

```bash
Usage:

  bundle exec ruby ./bench.rb URL QUANTITY CONCURRENCY [TIMEOUT=2000] [PROXY_LIST_FILE]

Arguments
=========
URL               Target URL to use for the benchmark.
QUANTITY          How many requests to execute for the test.
CONCURRENCY       How many parallel requests should be used to benchamrk the proxy.
                  The concurrency value cannot be higher than the quantity.
TIMEOUT           Optional. Request timeout before failure. Default: 2000.
PROXY_LIST_FILE   Optional. Proxy list file containing one proxy address per line.
```

## Getting started

First install all dependencies:

```bash
bundle install
```

Now you can execute the benchmark script, for example:

```bash
# benchmark without proxies
bundle exec ruby ./bench https://my-example.local 1000 10

# benchmakr using a proxy list
bundle exec ruby ./bench https://my-example.local 1000 10 2000 ./my_proxy_list.txt
```