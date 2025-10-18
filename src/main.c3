module torrent_client;

import std::io;
import libtorrent;

fn void main()
{
  io::printfn("Hello from torrent-client");
  libtorrent::greet();
}
