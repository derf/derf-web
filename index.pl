#!/usr/bin/env perl

use strict;
use warnings;
use 5.014;
use utf8;

use Encode qw(decode);
use File::MimeInfo qw(mimetype);
use List::MoreUtils qw(firstidx);
use Mojolicious::Lite;
use Mojolicious::Static;
use Mojolicious::Types;
use File::Path qw(make_path);
use File::Slurp qw(read_dir slurp);
use Image::Imlib2;

no if $] >= 5.018, warnings => "experimental::smartmatch";

our $VERSION = '0.00';
my $baseurl  = $ENV{BASEURL}      // 'https://fs.finalrewind.org';
my $prefix   = $ENV{EFS_PREFIX}   // '/home/derf/lib';
my $thumbdir = $ENV{EFS_THUMBDIR} // '/home/derf/var/local/efs-thumbs';
my $hwdb     = $ENV{HWDB_PATH}    // '/home/derf/packages/hardware/var/db';
my $listen   = $ENV{DWEB_LISTEN}  // 'http://127.0.0.1:8099';

my $type = Mojolicious::Types->new;

my @pgctl_devices = qw(
  fnordlicht lfan psu-12v psu-lastlight psu-saviour tbacklight tischlicht
);

my @hwdb_export = qw(
  RK SE SL SR S1 S5
);

my $re_hwdb_desc = qr{
	^
	(?<location> \S+ )
	\s* := \s*
	(?<description> .+ )
	$
}x;
my $re_hwdb_item = qr{
	^
	(?<location> [^|]+? )
	\s* \| \s*
	(?<amount> [^|]+ )
	\s* \| \s*
	(?<description> [^|]+ )
	(
		\s* \| \s*
		(?<extra> [^|]+ )
		$
	)?
}x;

sub pgctl_get_status {
	my ($device) = @_;

	if ( $device ~~ \@pgctl_devices ) {
		my $status = qx{$device};
		chomp $status;
		return $status ? 1 : 0;
	}
	return 0;
}

sub pgctl_set_status {
	my ( $device, $status ) = @_;

	if ( $device ~~ \@pgctl_devices ) {
		my $arg = $status ? 'on' : 'off';
		system( $device, $arg );
	}
	return;
}

sub efs_list_file {
	my ( $path, $file, $params ) = @_;
	my $realpath = "${prefix}/${path}/${file}";
	my $url;

	if ( -l $realpath ) {
		$realpath = "${prefix}/${path}/" . readlink($realpath);
	}

	if ( mimetype($realpath) =~ m{ ^ image }ox ) {
		$url = "/efs/${path}/${file}.html?${params}";
	}
	elsif ( -d $realpath ) {
		$url = "/efs/${path}/${file}/?${params}";
	}
	else {
		$url = "/efs/${path}/${file}";
	}

	return [ $file, $url, "/efs/${path}/${file}" ];
}

sub sort_filenames {
	my ( $mode, $prefix, @files ) = @_;
	my @ret;

	if ( $mode eq 'mtime' ) {
		@ret = map { $_->[0] }
		  sort { $a->[1] <=> $b->[1] }
		  map { [ $_, +( stat "${prefix}/$_" )[9] ] } @files;
	}
	else {
		@ret = sort @files;
	}

	return @ret;
}

sub load_hwdb {
	my ($self) = @_;
	my $db;
	my %descs;

	open( my $fh, '<', $hwdb );
	while ( my $line = <$fh> ) {
		chomp($line);

		if ( $line =~ $re_hwdb_desc ) {
			say "wat $+{location} := $+{description}";
			$descs{ $+{location} } = $+{description};
		}
		elsif ( $line =~ $re_hwdb_item ) {
			my $part = {
				location    => $+{location},
				locationv   => $descs{ $+{location} },
				amount      => $+{amount},
				description => decode( 'utf-8', $+{description} ),
			};
			if ( $+{extra} ) {
				my ( $shop, $artnr ) = split( /:/, $+{extra} );
				$part->{$shop} = $artnr;
			}
			push( @{$db}, $part );
		}
	}

	return $db;
}

sub serve_efs {
	my $self = shift;
	my $path = $self->stash('path') || q{.};
	my $sort = $self->param('sort') || 'name';

	my $param_s = $self->req->params->to_string;

	my ( $dir, $file ) = ( $path =~ m{ ^ (.+) / ([^/]+) \. html $ }ox );

	if ( $path =~ m{ \. html $ }ox ) {

		my @all_files = read_dir("${prefix}/${dir}");
		@all_files = grep { -f "${prefix}/${dir}/$_" } @all_files;

		@all_files = sort_filenames( $sort, "${prefix}/${dir}", @all_files );

		my $idx = firstidx { $_ eq $file } @all_files;

		my $prev_idx = ( $idx == 0           ? 0    : $idx - 1 );
		my $next_idx = ( $idx == $#all_files ? $idx : $idx + 1 );

		$self->render(
			'efs-main',
			prev       => $all_files[$prev_idx],
			next       => $all_files[$next_idx],
			randomlink => $all_files[ int( rand($#all_files) ) ],
			prevlink   => $all_files[$prev_idx] . ".html?${param_s}",
			nextlink   => $all_files[$next_idx] . ".html?${param_s}",
			randomlink => $all_files[ int( rand($#all_files) ) ]
			  . ".html?${param_s}",
			parentlink => $dir,
			file       => $file,
		);
	}
	elsif ( -d "${prefix}/${path}" ) {
		$path =~ s{ / $ }{}ox;
		my @all_files = read_dir( "${prefix}/${path}", keep_dot_dot => 1 );
		@all_files = sort_filenames( $sort, "${prefix}/${path}", @all_files );
		@all_files = map { efs_list_file( $path, $_, $param_s ) } @all_files;
		$self->render( 'efs-list', files => \@all_files, );
	}
	else {
		if ( $self->param('thumb') ) {

			my $thumb_path = $path;
			$thumb_path =~ s{ \. gif $ }{.png}ox;

			if ( not -e "${thumbdir}/thumbs/${path}" ) {
				my $im        = Image::Imlib2->load("${prefix}/${path}");
				my $thumb     = $im;
				my $thumb_dim = 250;
				my ( $dx, $dy ) = ( $im->width, $im->height );

				my ( $dpath, $file ) = ( $path =~ m{ (.+) / ([^/])+ $ }ox );

				make_path("${thumbdir}/thumbs/${dpath}");

				if ( $dx > $thumb_dim or $dy > $thumb_dim ) {
					if ( $dx > $dy ) {
						$thumb = $im->create_scaled_image( $thumb_dim, 0 );
					}
					else {
						$thumb = $im->create_scaled_image( 0, $thumb_dim );
					}
				}
				$thumb->set_quality(75);
				$thumb->save("${thumbdir}/thumbs/${thumb_path}");
			}
			$path = "thumbs/${thumb_path}";
		}
		my $fn = ( split( qr{/},   $path ) )[-1];
		my $ft = ( split( qr{[.]}, $fn ) )[-1];
		my $ct = $type->type($ft);
		$self->res->headers->content_disposition("inline; filename=${fn}");
		$self->res->headers->content_type("$ct; name=${fn}");
		$self->render_static($path);
	}

}

sub serve_hwdb {
	my ($self) = @_;
	my $db = load_hwdb;

	$self->render( 'hwdb-list', db => $db );

}

sub serve_pgctl {
	my ($self) = @_;

	my %devices;

	for my $device (@pgctl_devices) {
		$devices{$device} = pgctl_get_status($device) ? 'on' : 'off';
	}

	$self->render( 'pgctl', devices => \%devices, );

	return;
}

sub serve_pgctl_toggle {
	my ($self) = @_;
	my $device = $self->stash('device');

	pgctl_set_status( $device, !pgctl_get_status($device) );

	$self->redirect_to("${baseurl}/pgctl");
	return;
}

get '/efs/'                 => \&serve_efs;
get '/efs/*path'            => \&serve_efs;
get '/hwdb/'                => \&serve_hwdb;
get '/pgctl'                => \&serve_pgctl;
get '/pgctl/toggle/:device' => \&serve_pgctl_toggle;

app->config(
	hypnotoad => {
		listen   => [$listen],
		pid_file => '/tmp/derf_web.pid',
		workers  => 2,
	},
);

app->defaults( layout => 'default' );
push( @{ app->static->paths }, $prefix );
push( @{ app->static->paths }, $thumbdir );

app->start;
