module torrent_client;

import std::io;
import libtorrent;

fn void main()
{
  io::printfn("Hello from torrent-client");
  // TODO: Add command-line argument parsing
  // TODO: Parse .torrent file using libtorrent::torrent::parse()
}
