use clap::Parser;
use std::fs::File;
use std::io::{self, BufRead, BufReader, Read};
use std::path::PathBuf;
use std::time::Instant;
use std::{cmp, thread};
use tantivy::schema::*;
use tantivy::{doc, Document, Index, IndexWriter, TantivyDocument};

#[derive(Parser)]
#[command(version, about, long_about=Some("Turn titles.txt into a tantivy search index"))]
struct Args {
    #[arg(long)]
    r#in: String,
    #[arg(long)]
    out: String,

    #[arg(short, long, default_value_t = 4)]
    threads: usize,
}

fn main() -> tantivy::Result<()> {
    let args = Args::parse();

    let path = PathBuf::from(&args.out);

    assert!(path.is_dir());

    let mut schema_builder = Schema::builder();

    schema_builder.add_text_field("title", TEXT | STORED | FAST);
    schema_builder.add_u64_field("id", STORED | FAST);

    let schema = schema_builder.build();

    let index = Index::create_in_dir(&path, schema.clone())?;

    let doc_src = if args.r#in.len() > 0 {
        DocumentSource::FromFile(PathBuf::from(&args.r#in))
    } else {
        DocumentSource::FromPipe
    };

    run_index(
        index,
        path,
        doc_src,
        20_000_000 * args.threads,
        args.threads,
    )?;

    Ok(())
}

// ****************
// From tantivy-cli
// ****************

fn run_index(
    index: Index,
    directory: PathBuf,
    document_source: DocumentSource,
    buffer_size_per_thread: usize,
    num_threads: usize,
) -> tantivy::Result<()> {
    let schema = index.schema();
    let (line_sender, line_receiver) = crossbeam_channel::bounded(100);
    let (doc_sender, doc_receiver) = crossbeam_channel::bounded(100);

    thread::spawn(move || {
        let articles = document_source.read().unwrap();
        for (id, article_line_res) in articles.lines().enumerate() {
            let title = article_line_res.unwrap();
            // TODO: sub HTML ENTITIES for chars
            line_sender.send((id, title)).unwrap();
        }
    });

    let num_threads_to_parse_json = cmp::max(1, num_threads / 4);
    println!("Using {} threads to parse json", num_threads_to_parse_json);
    for _ in 0..num_threads_to_parse_json {
        let schema_clone = schema.clone();
        let doc_sender_clone = doc_sender.clone();
        let line_receiver_clone = line_receiver.clone();
        thread::spawn(move || {
            for doc_data in line_receiver_clone {
                let id = schema_clone.find_field("id").unwrap().0;
                let title = schema_clone.find_field("title").unwrap().0;

                let doc = doc!(
                    id => doc_data.0 as u64,
                    title => doc_data.1.clone(),
                );

                doc_sender_clone.send((doc, doc_data.1.len())).unwrap();
            }
        });
    }
    drop(doc_sender);

    let mut index_writer: IndexWriter<TantivyDocument> = if num_threads > 0 {
        index.writer_with_num_threads(num_threads, buffer_size_per_thread)
    } else {
        index.writer(buffer_size_per_thread)
    }?;

    let start_overall = Instant::now();
    let index_result = index_documents(&mut index_writer, doc_receiver);
    {
        let duration = start_overall - Instant::now();
        log::info!("Indexing the documents took {} s", duration.as_secs());
    }

    match index_result {
        Ok(res) => {
            println!("Commit succeed, docstamp at {}", res.docstamp);
            println!("Waiting for merging threads");

            let elapsed_before_merge = Instant::now() - start_overall;

            let doc_mb = res.num_docs_byte as f32 / 1_000_000_f32;
            let through_put = doc_mb / elapsed_before_merge.as_secs_f32();
            println!("Total Nowait Merge: {:.2} Mb/s", through_put);

            index_writer.wait_merging_threads()?;

            run_merge(directory)?;

            let elapsed_after_merge = Instant::now() - start_overall;

            let doc_mb = res.num_docs_byte as f32 / 1_000_000_f32;
            let through_put = doc_mb / elapsed_after_merge.as_secs() as f32;
            println!("Total Wait Merge: {:.2} Mb/s", through_put);

            println!("Terminated successfully!");
            {
                let duration = start_overall - Instant::now();
                log::info!(
                    "Indexing the documents took {} s overall (indexing + merge)",
                    duration.as_secs()
                );
            }
            Ok(())
        }
        Err(e) => {
            println!("Error during indexing, rollbacking.");
            index_writer.rollback().unwrap();
            println!("Rollback succeeded");
            Err(e)
        }
    }
}

struct IndexResult {
    docstamp: u64,
    num_docs_byte: usize,
}

fn index_documents<D: Document>(
    index_writer: &mut IndexWriter<D>,
    doc_receiver: crossbeam_channel::Receiver<(D, usize)>,
) -> tantivy::Result<IndexResult> {
    let mut num_docs_total = 0;
    let mut num_docs = 0;
    let mut num_docs_byte = 0;
    let mut num_docs_byte_total = 0;

    let mut last_print = Instant::now();
    for (doc, doc_size) in doc_receiver {
        index_writer.add_document(doc)?;

        num_docs_total += 1;
        num_docs += 1;
        num_docs_byte += doc_size;
        num_docs_byte_total += doc_size;
        if num_docs % 128 == 0 {
            let new = Instant::now();
            let elapsed_since_last_print = new - last_print;
            if elapsed_since_last_print.as_secs() as f32 > 1.0 {
                log::info!("{} Docs", num_docs_total);
                let doc_mb = num_docs_byte as f32 / 1_000_000_f32;
                let through_put = doc_mb / elapsed_since_last_print.as_secs() as f32;
                println!(
                    "{:.0} docs / hour {:.2} Mb/s",
                    num_docs as f32 * 3600.0 * 1_000_000.0_f32
                        / (elapsed_since_last_print.as_micros() as f32),
                    through_put
                );
                last_print = new;
                num_docs_byte = 0;
                num_docs = 0;
            }
        }
    }
    let res = index_writer.commit()?;

    Ok(IndexResult {
        docstamp: res,
        num_docs_byte: num_docs_byte_total,
    })
}

enum DocumentSource {
    FromPipe,
    FromFile(PathBuf),
}

impl DocumentSource {
    fn read(&self) -> io::Result<BufReader<Box<dyn Read>>> {
        Ok(match self {
            &DocumentSource::FromPipe => BufReader::new(Box::new(io::stdin())),
            DocumentSource::FromFile(filepath) => {
                let read_file = File::open(filepath)?;
                BufReader::new(Box::new(read_file))
            }
        })
    }
}

pub fn run_merge(path: PathBuf) -> tantivy::Result<()> {
    let index = Index::open_in_dir(&path)?;
    let segments = index.searchable_segment_ids()?;
    let segment_meta = index
        .writer::<TantivyDocument>(300_000_000)?
        .merge(&segments)
        .wait()?;
    log::info!("Merge finished with segment meta {:?}", segment_meta);
    log::info!("Garbage collect irrelevant segments.");
    Index::open_in_dir(&path)?
        .writer_with_num_threads::<TantivyDocument>(1, 40_000_000)?
        .garbage_collect_files()
        .wait()?;
    Ok(())
}
