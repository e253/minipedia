use core::str;
use std::mem::ManuallyDrop;
use std::path::PathBuf;
use tantivy::collector::TopDocs;
use tantivy::query::QueryParser;
use tantivy::schema::OwnedValue;
use tantivy::{Index, IndexReader, TantivyDocument};

#[repr(C)]
pub struct State {
    pub index: *mut Index,
    pub reader: *mut IndexReader,
}

#[repr(C)]
pub struct Result {
    pub title: *const u8,
    pub title_len: usize,
    pub doc_id: usize,
}

/// Public functions.

#[no_mangle]
pub extern "C" fn ms_init(s: *mut State, index_dir: *const u8, index_dir_len: usize) -> () {
    assert!(!index_dir.is_null());
    assert!(!s.is_null());

    let index_dir =
        unsafe { str::from_utf8_unchecked(std::slice::from_raw_parts(index_dir, index_dir_len)) };

    let index_dir = PathBuf::from(index_dir);

    let index = Index::open_in_dir(index_dir).expect("Index not found");

    let reader = index.reader().expect("Reader cannot be found");

    unsafe {
        *s = State {
            index: ManuallyDrop::new(Box::new(index)).as_mut() as *mut Index,
            reader: ManuallyDrop::new(Box::new(reader)).as_mut() as *mut IndexReader,
        };
    }
}

#[no_mangle]
pub extern "C" fn ms_search(
    s: *const State,
    query: *const u8,
    query_len: usize,
    limit: usize,
    offset: usize,
    results_buf: *mut Result,
    mut title_buf: *mut u8,
) -> usize {
    assert!(!results_buf.is_null());

    let (index, reader) = unsafe { parts_from_state(s) };
    let schema = index.schema();
    let title_field = schema.find_field("title").unwrap().0;
    let searcher = reader.searcher();

    let query = unsafe { str::from_utf8_unchecked(std::slice::from_raw_parts(query, query_len)) };

    let query_parser = QueryParser::for_index(&index, vec![title_field]);

    let query = query_parser
        .parse_query(query)
        .expect("Query parsing failed");

    let results = searcher
        .search(&query, &TopDocs::with_limit(limit + offset))
        .expect("Error processing query");

    if results.len() == 0 {
        return 0;
    }

    for (i, (_, doc_address)) in (&results).into_iter().skip(offset).enumerate() {
        let doc: TantivyDocument = searcher.doc(*doc_address).unwrap();
        let doc_values = doc.field_values();
        assert!(doc_values.len() == 2);

        let doc_id = match &doc_values[0].value {
            OwnedValue::U64(id) => id.to_owned() as usize,
            _ => panic!("Non u64 field found in pos 0 of field values"),
        };
        let title = match &doc_values[1].value {
            OwnedValue::Str(s) => s,
            _ => panic!("Non string field found in pos 1 of field values"),
        };

        let result = Result {
            title: title_buf,
            title_len: title.len(),
            doc_id,
        };

        unsafe {
            std::ptr::copy_nonoverlapping(title.as_ptr(), title_buf, title.len());
            title_buf = title_buf.add(title.len());
        }

        unsafe {
            *results_buf.add(i) = result;
        }
    }

    results.len()
}

#[no_mangle]
pub extern "C" fn ms_deinit(state: *const State) -> () {
    assert!(!state.is_null());
    unsafe {
        let state = &*state;
        drop(Box::from_raw(state.index));
        drop(Box::from_raw(state.reader));
    }
}

unsafe fn parts_from_state(
    state: *const State,
) -> (ManuallyDrop<Box<Index>>, ManuallyDrop<Box<IndexReader>>) {
    assert!(!state.is_null());
    let state = &*state;

    (
        ManuallyDrop::new(Box::from_raw(state.index)),
        ManuallyDrop::new(Box::from_raw(state.reader)),
    )
}
