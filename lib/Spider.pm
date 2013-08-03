package Spider;

use Modern::Perl;
use Moose;
use Data::Dumper;
use LWP::UserAgent;
use HTTP::Request::Common qw(GET);
use HTTP::Cookies;
use HTML::TreeBuilder;

use base qw/ Exporter /;
our @EXPORT = qw/ find_origin /;

has [qw/output_file links/] => (
  is => 'rw',
  required => 1,
);

has [qw/keywords allowed_keywords debug_enabled web_depth/] => (
  is => 'ro',
  required => 1,
);

has 'output' => (
  traits => ['String'],
  is => 'rw',
  isa => 'Str',
  default => '',
  handles => {
    add_text     => 'append',
  },
);

has 'counted' => (
  is => 'rw',
  default => 0,
);

has [qw/website origin origin_domain root alerted/] => (
  is => 'rw',
);

$ENV{PERL_LWP_SSL_VERIFY_HOSTNAME} = 0;

my $ua = LWP::UserAgent->new;
$ua->agent('Mozilla/8.0');
$ua->cookie_jar(
  HTTP::Cookies->new(
    file => 'mycookies.txt',
    autosave => 1
  )
);
$ua->timeout(15);
$ua->max_size(512*1024);

sub find_origin {
  my ($url) = @_;

  my $origin = $url;
  $origin =~ s/https?:\/\///;
  $origin =~ s/\/.*$//;

  my $domain = $origin;
  $domain =~ s/www\.//;

  return ($origin, $domain);
}

sub debug {
  my ($self, $string) = @_;

  if($self->debug_enabled) {
    print "$string";
  }

  return;
}

sub is_already_crawled {
  my ($self) = @_;

#  print Dumper \$self->links;
  foreach (keys %{$self->links}) {
    # max depth in links hash can be 1 now
    if ($self->links->{$_}{depth} == 1 && not defined $self->links->{$_}{fetched}) {
      return 0;
    }
  }

  return 1;
}

sub get_root {
  my ($self, $url) = @_;

  my $req = GET $url;

  my $res = $ua->request($req);

  if ($res->is_success) {
    if (
      ($res->header('Content-Type') =~ /^text\/html/ ||
        $res->header('Content-Type') =~ /xml$/ ) &&
      ((not defined $res->header('Content-Length')) ||
        $res->header('Content-Length') < 512*1024)
    ) {
      my $content = $res->content;

      $self->root(HTML::TreeBuilder->new_from_content($content));

    } else{
      $self->add_text('SKIPPING because of content type or length' . "\n");
    }
  } else {
      $self->add_text('ERROR:' . $res->status_line . "\n");
  }
}


sub get_content_with_meta_keywords {
  my ($self) = @_;

  my $meta_keywords =
    (defined $self->root->find_by_attribute('name', 'keywords')) ?
      $self->root->find_by_attribute('name', 'keywords')->attr('content') : '';

  my $content_with_meta_keywords = $self->root->as_text . $meta_keywords;

  return $content_with_meta_keywords;
}

sub _add_new_link {
  my ($self, $link, $depth) = @_;
  if (not exists $self->links->{$link}) {
    $self->links->{$link} = {
      depth => $depth,
    };
  }

  return;
}

sub _handle_non_http_link {
  my ($self, $link, $base, $depth) = @_;

  my $href;

  if ($link =~ /^\//) {
    $href = "http://" . $self->origin . $link;
  }
  elsif ($link =~ /^\.\.\//) {
    my $dwo_dots_base = $base;

    while ($link =~ /^\.\.\//) {
      $link =~ s/^\.\.\///;
      $dwo_dots_base =~ s/[\.\-_\w]+\/$//;
    }

    if ($dwo_dots_base =~ /$self->origin_domain/) {
      $href = $dwo_dots_base . $link;
    } else {
      $href = 'http://' . $self->origin . '/' . $link;
    }
  }
  else {
    # get rif of './'
    $link =~ s/^\.\///;
    $href = $base . $link;
  }

  $self->_add_new_link($href, $depth);
}

sub _remove_link_garbage {
  my $link = shift;
  $link =~ s/\#.*$//;
  $link =~ s/^\s+//;
  $link =~ s/[\r\n]+//g;

  foreach my $unwanted_param ('share', 'link') {
    if ( $link =~ /[\?\&]${unwanted_param}=/ ) {
      $link =~ s/${unwanted_param}=.*&//g;
      $link =~ s/${unwanted_param}=.*$//g;
    }
  }

  $link =~ s/&$//g;

  return $link;
}

sub get_base {
  my ($base) = @_;

  # get url til the first slash
  $base =~ s#^(http:\/\/.+/).*#$1#;

  if ($base !~ /\/$/) {
    $base = $base . '/';
  }

  return $base;
}

sub _handle_link {
  my ($self, $link, $base, $depth) = @_;

  if ($link !~ /^http/ ) {
    $self->_handle_non_http_link($link, $base, $depth);
  }
  else {
    my $origin_domain = $self->origin_domain;

    if ($link =~ /^https?:\/\/(www\.)?[a-z\.\-]*${origin_domain}/i) {
      $self->_add_new_link($link, $depth);
    }
  }
}

sub add_links_from_root {
  my ($self, $depth, $url) = @_;

  my @anchors = $self->root->find('a');

  # base is for concatenating links like 'journal.html'
  my $base = get_base($url);

  foreach (@anchors) {
    my $link = $_->attr('href');

    if ($link) {
      $link = _remove_link_garbage($link);

      if ($link =~ /^(mailto|javascript):/i
        ||
        # there can be also space in the end
        $link =~ /\.(mp3|mp4|avi|bmp|gif|jpg|jpeg|zip|rar|msi|exe|png|gz|bz2|tar|swf|pdf|wav|asf|tgz|wmv|flv|rm|mpg)\s?$/i
      ) {
        next;
      }

      $self->_handle_link($link, $base, $depth);
    }
  }
}

sub check_website {
  my ($self, $url) = @_;
  my $content_with_meta_keywords = $self->get_content_with_meta_keywords();

  my $is_alerted = 0;
  my @matched_keywords = ();
  foreach (@{$self->keywords}) {
    if ( $content_with_meta_keywords  =~ /$_/i ) {
      push @matched_keywords, $_;
      if (!exists($self->allowed_keywords->{$_})) {
        $is_alerted = 1;
      }
    }
  }

  $self->add_text("ALERT ") if $is_alerted;

  my $keyword_count = scalar @matched_keywords;

  if ($keyword_count > 0) {
    $self->add_text("possible bad content $url @matched_keywords\n");
    $self->add_text("found keywords: $keyword_count\n\n");
  }

  return $is_alerted;
}

sub fetch_website {
  my ($self, $url, $want_spider, $depth) = @_;

#  print Dumper $self->links;
  $self->root(0);
  $self->get_root($url);

  if (!$self->root) {
    return 0;
  }

  if ($want_spider) {
    $self->add_links_from_root($depth, $url);
  }

  return $self->check_website($url);
}

sub spider_website {
  my ($self) = @_;

  my $start = time;
  $self->debug("TIME".$start."\n");

  # fetch initial website
  my $want_spider = 1;
  my $max_depth = 1;
  $self->alerted(
    $self->fetch_website($self->website, $want_spider, $max_depth));

  $self->debug("PO:\n");
  $self->debug(Dumper $self->links);
# ma is_already_crawled ked tam uz mozu byt linky ktore maju vacsiu depth ako 1 ?
# ale z tej jednej startovacej url nemozu by linky s depth vacsie ako 1

  my @keys = keys %{$self->links};

  # checks if there are other urls than initial
  if (@keys && !$self->is_already_crawled()) {

    # website is spidered to web_depth
    # referrer to depth = 1
    $want_spider = $self->links->{$self->website}{want_spider} // 0;
    $max_depth = ($want_spider) ? $self->web_depth : 1;

    $self->debug("MAAAAAAX ". $self->website ." $max_depth\n");

    for (my $depth = 1; $depth <= $max_depth; $depth++) {
      $self->debug("DEPTH".$depth."\n");

      $self->proceed($start, $depth, $want_spider);
    }
  }

  return;
}

sub proceed {
  my ($self, $start, $depth, $want_spider) = @_;

  # fetch_website adds urls to links
  my @keys = keys %{$self->links};
  foreach (@keys) {
    if ($self->links->{$_}{depth} == ($depth) && not defined $self->links->{$_}{fetched}) {
      # skip forums
      if ($_ =~ /forums?\/index.php/) {
        $self->add_text("SKIPPING $_\n");
        $self->links->{$_}{fetched} = 1;
        next;
      }

      if ( (time - $start) > 120 ) {
        $self->add_text("TIMEOUT $self->website, number of links = ". (scalar @keys) ."\n");
        last;
      }
      else {
        $self->debug("fetching $_\n");
        $self->add_text("fetching $_\n");
      }

      my $returned = $self->fetch_website($_, $want_spider, $depth+1);
      $self->links->{$_}{fetched} = 1;
      if ($returned) {
        $self->alerted(1);
      }
    }
  }

  return;
}

sub settle_website {
  my ($self, $website) = @_;

  $self->links->{$website}{fetched} = 1;

  $self->debug("SPIDER ".$website."\n");
  $self->add_text("\nSPIDER ".$website."\n");

  if ( $website !~ /http/ ) {
    $website = 'http://' . $website;
  }

  $self->website($website);

  # origin* may be different for website and for referrer
  my ($origin, $origin_domain) = find_origin($website);
  $self->origin($origin);
  $self->origin_domain($origin_domain);

  $self->debug("ORIGIN". $origin ."\n");
  $self->debug("DOMAIN". $origin_domain ."\n");

  $self->debug("PRED:\n");
  $self->debug(Dumper $self->links);

  return;
}

sub spider_links {
  my ($self) = @_;

  $self->add_text("SPIDER LINKS\n");
#  print Dumper $self->links;

  my @zero_keys = keys %{$self->links};

  foreach (@zero_keys) {
#    print Dumper $self->links->{$_}{depth};
#  print "ZERO " . $_ ."\n";
    $self->settle_website($_);
    $self->spider_website();
    $self->counted(1) if ($self->alerted);
  }

  if ($self->counted) {
    $self->add_text("this IS counted as alerted\n\n");
  } else {
    $self->add_text("this IS NOT counted as alerted\n\n");
  }

  print {$self->output_file()} $self->output;
  print {$self->output_file()} "----------------------------------------------------------------------\n\n";

  return $self->counted;
}

1;
