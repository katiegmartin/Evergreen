#!/usr/bin/perl -w

use strict;
use diagnostics;
use DBI;
use FileHandle;
use XML::LibXML;
use Getopt::Long;
use DateTime;
use DateTime::Format::ISO8601;
use JSON;
use Data::Dumper;
use Text::CSV_XS;
use Spreadsheet::WriteExcel::Big;
use OpenSRF::EX qw/:try/;
use OpenSRF::Utils qw/:daemon/;
use OpenSRF::Utils::Logger qw/:level/;
use OpenSRF::System;
use OpenSRF::AppSession;
use OpenSRF::Utils::SettingsClient;
use OpenILS::Reporter::SQLBuilder;
use POSIX;
use GD::Graph::pie;
use GD::Graph::bars3d;
use GD::Graph::lines3d;
use Tie::IxHash;

use open ':utf8';


my ($count, $config, $lockfile, $daemon) = (1, '/openils/conf/bootstrap.conf', '/tmp/reporter-LOCK');

GetOptions(
	"daemon"	=> \$daemon,
	"concurrency=i"	=> \$count,
	"boostrap=s"	=> \$config,
	"lockfile=s"	=> \$lockfile,
);

if (-e $lockfile) {
	die "I seem to be running already. If not remove $lockfile, try again\n";
}

open(F, ">$lockfile");
print F $$;
close F;

OpenSRF::System->bootstrap_client( config_file => $config );

# XXX Get this stuff from the settings server
my $sc = OpenSRF::Utils::SettingsClient->new;
my $db_driver = $sc->config_value( reporter => setup => database => 'driver' );
my $db_host = $sc->config_value( reporter => setup => database => 'host' );
my $db_port = $sc->config_value( reporter => setup => database => 'port' );
my $db_name = $sc->config_value( reporter => setup => database => 'name' );
my $db_user = $sc->config_value( reporter => setup => database => 'user' );
my $db_pw = $sc->config_value( reporter => setup => database => 'password' );

my $output_base = $sc->config_value( reporter => setup => files => 'output_base' );

my $dsn = "dbi:" . $db_driver . ":dbname=" . $db_name .';host=' . $db_host . ';port=' . $db_port;

my ($dbh,$running,$sth,@reports,$run, $current_time);

daemonize("Clark Kent, waiting for trouble") if ($daemon);

DAEMON:

$dbh = DBI->connect($dsn,$db_user,$db_pw, {pg_enable_utf8 => 1, RaiseError => 1});

$current_time = DateTime->from_epoch( epoch => time() )->strftime('%FT%T%z');

# make sure we're not already running $count reports
($running) = $dbh->selectrow_array(<<SQL);
SELECT	count(*)
  FROM	reporter.schedule
  WHERE	start_time IS NOT NULL AND complete_time IS NULL;
SQL

if ($count <= $running) {
	if ($daemon) {
		$dbh->disconnect;
		sleep 1;
		POSIX::waitpid( -1, POSIX::WNOHANG );
		sleep 60;
		goto DAEMON;
	}
	print "Already running maximum ($running) concurrent reports\n";
	exit 1;
}

# if we have some open slots then generate the sql
$run = $count - $running;

$sth = $dbh->prepare(<<SQL);
SELECT	*
  FROM	reporter.schedule
  WHERE	start_time IS NULL AND run_time < NOW()
  ORDER BY run_time
  LIMIT $run;
SQL

$sth->execute;

@reports = ();
while (my $r = $sth->fetchrow_hashref) {
	my $s3 = $dbh->selectrow_hashref(<<"	SQL", {}, $r->{report});
		SELECT * FROM reporter.report WHERE id = ?;
	SQL

	my $s2 = $dbh->selectrow_hashref(<<"	SQL", {}, $s3->{template});
		SELECT * FROM reporter.template WHERE id = ?;
	SQL

	$s3->{template} = $s2;
	$r->{report} = $s3;

	my $b = OpenILS::Reporter::SQLBuilder->new;
	$b->register_params( JSON->JSON2perl( $r->{report}->{data} ) );

	$r->{resultset} = $b->parse_report( JSON->JSON2perl( $r->{report}->{template}->{data} ) );
	push @reports, $r;
}

$sth->finish;

$dbh->disconnect;

# Now we spaun the report runners

for my $r ( @reports ) {
	next if (safe_fork());

	# This is the child (runner) process;
	daemonize("Clark Kent reporting: $r->{report}->{name}");

	$dbh = DBI->connect($dsn,$db_user,$db_pw, {pg_enable_utf8 => 1, RaiseError => 1});

	try {
		$dbh->do(<<'		SQL',{}, $r->{id});
			UPDATE	reporter.schedule
			  SET	start_time = 'now',
			  WHERE	id = ?;
		SQL

		$sth = $dbh->prepare($r->{resultset}->toSQL);

		$sth->execute;
		$r->{data} = $sth->fetchall_arrayref;

		$r->{column_labels} = [$r->{resultset}->column_label_list];

		if ($r->{resultset}->pivot_data && $r->{resultset}->pivot_label) {
			my @labels = $r->{resultset}->column_label_list;
			my $newdata = pivot_data(
				{ columns => $r->{column_labels}, data => $r->{data}},
				$r->{resultset}->pivot_label,
				$r->{resultset}->pivot_data,
				$r->{resultset}->pivot_default
			);

			$r->{column_labels} = $newdata->{columns};
			$r->{data} = $newdata->{data};
		}

		my $s2 = $r->{report}->{template}->{id};
		my $s3 = $r->{report}->{id};
		my $output = $r->{id};

		mkdir($output_base);
		mkdir("$output_base/$s2");
		mkdir("$output_base/$s2/$s3");
		mkdir("$output_base/$s2/$s3/$output");
	
		my $output_dir = "$output_base/$s2/$s3/$output";

		if ( $r->{csv_format} eq 't') {
			build_csv("$output_dir/report-data.csv", $r);
		}

		if ( $r->{excel_format} eq 't') {
			build_excel("$output_dir/report-data.xls", $r);
		}

		if ( $r->{html_format} eq 't') {
			mkdir("$output_dir/html");
			build_html("$output_dir/report-data.html", $r);
		}


		$dbh->begin_work;

		if ($r->{report}->{recur} eq 't') {
			my $sql = <<'			SQL';
				INSERT INTO reporter.schedule ( report, folder, runner, run_time, email, csv_format, excel_format, html_format)
					VALUES ( ?, ?, ?, NOW() + ?, ?, ?, ?, ? );
			SQL

			$dbh->do(
				$sql,
				{},
				$r->{report}->{id},
				$r->{folder},
				$r->{runner},
				$r->{report}->{recurance},
				$r->{email},
				$r->{csv_format},
				$r->{excel_format},
				$r->{html_format}
			);
		}

		$dbh->do(<<'		SQL',{}, $r->{id});
			UPDATE	reporter.schedule
			  SET	complete_time = 'now'
			  WHERE	id = ?;
		SQL

		$dbh->commit;


	} otherwise {
		my $e = shift;
		$dbh->rollback;
		$dbh->do(<<'		SQL',{}, $e, $r->{id});
			UPDATE	reporter.schedule
			  SET	error_text = ?,
			  	complete_time = 'now',
				error_code = 1,
			  WHERE	id = ?;
		SQL
	};

	$dbh->disconnect;

	exit; # leave the child
}

if ($daemon) {
	sleep 1;
	POSIX::waitpid( -1, POSIX::WNOHANG );
	sleep 60;
	goto DAEMON;
}

#-------------------------------------------------------------------

sub build_csv {
	my $file = shift;
	my $r = shift;

	my $csv = Text::CSV_XS->new({ always_quote => 1, eol => "\015\012" });

	return unless ($csv);
	
	my $f = new FileHandle (">$file");

	$csv->print($f, $r->{column_labels});
	$csv->print($f, $_) for (@{$r->{data}});

	$f->close;
}
sub build_excel {
	my $file = shift;
	my $r = shift;
	my $xls = Spreadsheet::WriteExcel::Big->new($file);

	my $sheetname = substr($r->{report}->{name},1,31);
	$sheetname =~ s/\W/_/gos;
	
	my $sheet = $xls->add_worksheet($sheetname);

	$sheet->write_row('A1', $r->{column_labels});

	$sheet->write_col('A2', $r->{data});

	$xls->close;
}

sub build_html {
	my $file = shift;
	my $r = shift;

	my $index = new FileHandle (">$file");
	my $raw = new FileHandle (">$file.raw.html");
	
	# index header
	print $index <<"	HEADER";
<html>
	<head>
		<title>$$r{report}{name}</title>
		<style>
			table { border-collapse: collapse; }
			th { background-color: lightgray; }
			td,th { border: solid black 1px; }
			* { font-family: sans-serif; font-size: 10px; }
		</style>
	</head>
	<body>
		<h2><u>$$r{report}{name}</u></h2>
		$$r{report}{description}<br/><br/><br/>
	HEADER

	
	# add a link to the raw output html
	print $index "<a href='report-data.html.raw.html'>Tabular Output</a><br/><br/><br/><br/>";

	# create the raw output html file
	print $raw "<html><head><title>$$r{report}{name}</title>";

	print $raw <<'	CSS';
		<style>
			table { border-collapse: collapse; }
			th { background-color: lightgray; }
			td,th { border: solid black 1px; }
			* { font-family: sans-serif; font-size: 10px; }
		</style>
	CSS

	print $raw "</head><body><table>";

	{	no warnings;
		print $raw "<tr><th>".join('</th><th>',@{$r->{column_labels}}).'</th></tr>';
		print $raw "<tr><td>".join('</td><td>',@$_                   ).'</td></tr>' for (@{$r->{data}});
	}

	print $raw '</table></body></html>';
	
	$raw->close;

	# Time for a pie chart
	if ($r->{chart_pie} eq 't') {
		my $pics = draw_pie($r, $file);
		for my $pic (@$pics) {
			print $index "<img src='report-data.html.$pic->{file}' alt='$pic->{name}'/><br/><br/><br/><br/>";
		}
	}

	print $index '<br/><br/><br/><br/>';
	# Time for a bar chart
	if ($r->{chart_bar} eq 't') {
		my $pics = draw_bars($r, $file);
		for my $pic (@$pics) {
			print $index "<img src='report-data.html.$pic->{file}' alt='$pic->{name}'/><br/><br/><br/><br/>";
		}
	}

	print $index '<br/><br/><br/><br/>';
	# Time for a bar chart
	if ($r->{chart_line} eq 't') {
		my $pics = draw_lines($r, $file);
		for my $pic (@$pics) {
			print $index "<img src='report-data.html.$pic->{file}' alt='$pic->{name}'/><br/><br/><br/><br/>";
		}
	}

	# and that's it!
	print $index '</body></html>';
	
	$index->close;
}

sub draw_pie {
	my $r = shift;
	my $file = shift;

	my $data = $r->{data};

	my @groups = $r->{resultset}->group_by_list(0);
	
	my @values = (0 .. (scalar(@{$r->{column_labels}}) - 1));
	delete @values[@groups];

	#my $logo = $doc->findvalue('/reporter/setup/files/chart_logo');
	
	my @pics;
	for my $vcol (@values) {
		next unless (defined $vcol);

		my @pic_data = ([],[]);
		for my $row (@$data) {
			next if (!defined($$row[$vcol]) || $$row[$vcol] == 0);
			my $val = $$row[$vcol];
			push @{$pic_data[0]}, join(" -- ", @$row[@groups])." ($val)";
			push @{$pic_data[1]}, $val;
		}

		next unless (@{$pic_data[0]});

		my $size = 300;
		my $split = int(scalar(@{$pic_data[0]}) / $size);
		my $last = scalar(@{$pic_data[0]}) % $size;

		for my $sub_graph (0 .. $split) {
			
			if ($sub_graph == $split) {
				$size = $last;
			}

			my @sub_data;
			for my $set (@pic_data) {
				push @sub_data, [ splice(@$set,0,$size) ];
			}

			my $pic = new GD::Graph::pie;

			$pic->set(
				label			=> $r->{column_labels}->[$vcol],
				start_angle		=> 180,
				legend_placement	=> 'R',
				#logo			=> $logo,
				#logo_position		=> 'TL',
				#logo_resize		=> 0.5,
				show_values		=> 1,
			);

			my $format = $pic->export_format;

			open(IMG, ">$file.pie.$vcol.$sub_graph.$format");
			binmode IMG;

			my $forgetit = 0;
			try {
				$pic->plot(\@sub_data) or die $pic->error;
				print IMG $pic->gd->$format;
			} otherwise {
				my $e = shift;
				warn "Couldn't draw $file.pie.$vcol.$sub_graph.$format : $e";
				$forgetit = 1;
			};

			close IMG;


			push @pics,
				{ file => "pie.$vcol.$sub_graph.$format",
				  name => $r->{column_labels}->[$vcol].' (Pie)',
				} unless ($forgetit);

			last if ($sub_graph == $split);
		}

	}
	
	return \@pics;
}

sub draw_bars {
	my $r = shift;
	my $file = shift;
	my $data = $r->{data};

	#my $logo = $doc->findvalue('/reporter/setup/files/chart_logo');

	my @groups = $r->{resultset}->group_by_list(0);

	
	my @values = (0 .. (scalar(@{$r->{column_labels}}) - 1));
	splice(@values,$_,1) for (reverse @groups);

	my @pic_data;
	{	no warnings;
		for my $row (@$data) {
			push @{$pic_data[0]}, join(' -- ', @$row[@groups]);
		}
	}

	my @leg;
	my $set = 1;

	my %trim_candidates;

	my $max_y = 0;
	for my $vcol (@values) {
		next unless (defined $vcol);


		my $pos = 0;
		for my $row (@$data) {
			my $val = $$row[$vcol] ? $$row[$vcol] : 0;
			push @{$pic_data[$set]}, $val;
			$max_y = $val if ($val > $max_y);
			$trim_candidates{$pos}++ if ($val == 0);
			$pos++;
		}

		$set++;
	}
	my $set_count = scalar(@pic_data) - 1;
	my @trim_cols = grep { $trim_candidates{$_} == $set_count } keys %trim_candidates;

	my @new_data;
	my @use_me;
	my @no_use;
	my $set_index = 0;
	for my $dataset (@pic_data) {
		splice(@$dataset,$_,1) for (sort { $b <=> $a } @trim_cols);

		if (grep { $_ } @$dataset) {
			push @new_data, $dataset;
			push @use_me, $set_index;
		} else {
			push @no_use, $set_index;
		}
		$set_index++;
		
	}

	return [] unless ($new_data[0] && @{$new_data[0]});

	for my $col (@use_me) {
		push @leg, $r->{column_labels}->[$col + @groups - 1] if (map { 1 } grep { $col == $_ } @values);
	}

	my $w = 100 + 10 * scalar(@{$new_data[0]});
	$w = 400 if ($w < 400);

	my $h = 10 * (scalar(@new_data) / 2);

	$h = 0 if ($h < 0);

	my $pic = new GD::Graph::bars3d ($w + 250, $h + 500);

	$pic->set(
		title			=> $r->{report}{name},
		x_labels_vertical	=> 1,
		shading			=> 1,
		bar_depth		=> 5,
		bar_spacing		=> 2,
		y_max_value		=> $max_y,
		legend_placement	=> 'TR',
		boxclr			=> 'lgray',
		#logo			=> $logo,
		#logo_position		=> 'R',
		#logo_resize		=> 0.5,
		show_values		=> 1,
		overwrite		=> 1,
	);
	$pic->set_legend(@leg);

	my $format = $pic->export_format;

	open(IMG, ">$file.bar.$format");
	binmode IMG;

	try {
		$pic->plot(\@new_data) or die $pic->error;
		print IMG $pic->gd->$format;
	} otherwise {
		my $e = shift;
		warn "Couldn't draw $file.bar.$format : $e";
	};

	close IMG;

	return [{ file => "bar.$format",
		  name => $r->{report}{name}.' (Bar)',
		}];

}

sub draw_lines {
	my $r = shift;
	my $file = shift;
	my $data = $r->{data};

	#my $logo = $doc->findvalue('/reporter/setup/files/chart_logo');

	my @groups = $r->{resultset}->group_by_list(0);
	
	my @values = (0 .. (scalar(@{$r->{column_labels}}) - 1));
	splice(@values,$_,1) for (reverse @groups);

	my @pic_data;
	{	no warnings;
		for my $row (@$data) {
			push @{$pic_data[0]}, join(' -- ', @$row[@groups]);
		}
	}

	my @leg;
	my $set = 1;

	my $max_y = 0;
	for my $vcol (@values) {
		next unless (defined $vcol);


		for my $row (@$data) {
			my $val = $$row[$vcol] ? $$row[$vcol] : 0;
			push @{$pic_data[$set]}, $val;
			$max_y = $val if ($val > $max_y);
		}

		$set++;
	}
	my $set_count = scalar(@pic_data) - 1;

	my @new_data;
	my @use_me;
	my @no_use;
	my $set_index = 0;
	for my $dataset (@pic_data) {

		if (grep { $_ } @$dataset) {
			push @new_data, $dataset;
			push @use_me, $set_index;
		} else {
			push @no_use, $set_index;
		}
		$set_index++;
		
	}

	for my $col (@use_me) {
		push @leg, $r->{column_labels}->[$col + @groups - 1] if (map { 1 } grep { $col == $_ } @values);
	}

	my $w = 100 + 10 * scalar(@{$new_data[0]});
	$w = 400 if ($w < 400);

	my $h = 10 * (scalar(@new_data) / 2);

	$h = 0 if ($h < 0);

	my $pic = new GD::Graph::lines3d ($w + 250, $h + 500);

	$pic->set(
		title			=> $r->{report}{name},
		x_labels_vertical	=> 1,
		shading			=> 1,
		line_depth		=> 5,
		y_max_value		=> $max_y,
		legend_placement	=> 'TR',
		boxclr			=> 'lgray',
		#logo			=> $logo,
		#logo_position		=> 'R',
		#logo_resize		=> 0.5,
		show_values		=> 1,
		overwrite		=> 1,
	);
	$pic->set_legend(@leg);

	my $format = $pic->export_format;

	open(IMG, ">$file.line.$format");
	binmode IMG;

	try {
		$pic->plot(\@new_data) or die $pic->error;
		print IMG $pic->gd->$format;
	} otherwise {
		my $e = shift;
		warn "Couldn't draw $file.line.$format : $e";
	};

	close IMG;

	return [{ file => "line.$format",
		  name => $r->{report}{name}.' (Bar)',
		}];

}


sub pivot_data {
	my $blob = shift;
	my $pivot_label = shift;
	my $pivot_data = shift;
	my $default = shift;
	$default = 0 unless (defined $default);

	my $data = $$blob{data};
	my $cols = $$blob{columns};

	my @keep_labels =  @$cols;
	splice(@keep_labels, $_ - 1, 1) for (reverse sort ($pivot_label, $pivot_data));

	my @keep_cols = (0 .. @$cols - 1);
	splice(@keep_cols, $_ - 1, 1) for (reverse sort ($pivot_label, $pivot_data));

	#first, find the unique list of pivot values
	my %tmp;
	for my $row (@$data) {
		$tmp{ $$row[$pivot_label - 1] } = 1;
	}
	my @new_cols = sort keys %tmp;

	tie my %split_data, 'Tie::IxHash';
	for my $row (@$data) {

		my $row_fp = ''. join('', map { defined($$row[$_]) ? $$row[$_] : '' } @keep_cols);
		$split_data{$row_fp} ||= [];

		push @{ $split_data{$row_fp} }, $row;
	}


	#now loop over the data, building a new result set
	tie my %new_data, 'Tie::IxHash';

	for my $fp ( keys %split_data ) {

		$new_data{$fp} = [];

		for my $col (@keep_cols) {
			push @{ $new_data{$fp} }, $split_data{$fp}[0][$col];
		}

		for my $col (@new_cols) {

			my ($datum) = map { $_->[$pivot_data - 1] } grep { $_->[$pivot_label - 1] eq $col } @{ $split_data{$fp} };
			$datum ||= $default;
			push @{ $new_data{$fp} }, $datum;
		}
	}

	push @keep_labels, @new_cols;

	return { columns => \@keep_labels, data => [ values %new_data ] };
}


