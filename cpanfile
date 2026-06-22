requires 'perl', '5.036000';
requires 'Moo';
requires 'Text::Treesitter';
requires 'DBI';
requires 'DBD::SQLite', '1.72';
requires 'Cpanel::JSON::XS';
requires 'Path::Tiny';
requires 'Path::Iterator::Rule';
requires 'Digest::SHA';
requires 'POSIX';
requires 'Exporter';

# Runtime introspection (`pcg index --runtime`) — optional; loaded only when used.
recommends 'Devel::Symdump';
recommends 'Class::MOP';
# Event-driven `pcg watch` on Linux — optional; falls back to mtime polling without it.
recommends 'Linux::Inotify2';

on 'test' => sub {
    requires 'Test2::V0';
};
