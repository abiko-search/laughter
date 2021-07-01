# Laughter

![](https://github.com/abiko-search/laughter/workflows/Elixir%20CI/badge.svg)

A streaming HTML parser for Elixir built on top of the CloudFlare's 😂 [LOL HTML](https://github.com/cloudflare/lol-html)

## Usage

```elixir
iex> {:ok, {_, _, document}} = :httpc.request("https://en.wikipedia.org/wiki/The_Tor_Project")
{:ok,
 {{'HTTP/1.1', 200, 'OK'},
  [
    {'cache-control', 'private, s-maxage=0, max-age=0, must-revalidate'},
    {'connection', 'keep-alive'},
    {'date', 'Sat, 05 Jun 2021 08:41:57 GMT'},
    {'accept-ranges', 'bytes'},
    {'age', '22765'},
    {'server', 'ATS/8.0.8'},
    {'vary', 'Accept-Encoding,Cookie,Authorization'},
    {'content-language', 'en'},
    {'content-length', '133252'},
    {'content-type', 'text/html; charset=UTF-8'},
    {'last-modified', 'Thu, 03 Jun 2021 18:22:23 GMT'}
  ], '<!DOCTYPE html>\n<html class="client-nojs" lang="en' ++ ...}}

iex> builder = Laughter.build()
#Reference<0.2639616589.3816685576.219236>

iex> Laughter.filter(builder, self(), "a.external.text")          
#Reference<0.2639616589.3816685576.219237>

iex> builder
#Reference<0.2639616589.3816685576.219236>
iex> |> Laughter.create()
#Reference<0.2639616589.3816685576.219238>
iex> |> Laughter.parse(to_string(document))
#Reference<0.2639616589.3816685576.219238>
iex> |> Laughter.done()
:ok

iex> flush()
{:element, #Reference<0.2639616589.3816685576.219237>,
 {"a",
  [
    {"rel", "nofollow"},
    {"class", "external text"},
    {"href", "https://www.torproject.org"}
  ]}}
{:element, #Reference<0.2639616589.3816685576.219237>,
 {"a",
  [
    {"class", "external text"},
    {"href",
     "https://en.wikipedia.org/w/index.php?title=The_Tor_Project&amp;action=edit"}
  ]}}

# ...
```


## Installation

```elixir
def deps do
  [
    {:laughter, "~> 0.1.0-dev", github: "abiko-search/laughter", submodules: true}
  ]
end
```

## License

[Apache 2.0] © [Danila Poyarkov]

[Apache 2.0]: LICENSE
[Danila Poyarkov]: http://dannote.net
