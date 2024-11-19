use std::ffi::{c_char, CStr};
use std::path::PathBuf;
use tantivy::{Index, IndexReader};

#[repr(C)]
pub struct State {
    pub reader: *const IndexReader,
}

#[no_mangle]
pub extern "C" fn init_search(s: *mut State, index_dir: *const c_char) -> bool {
    let index_dir = unsafe { CStr::from_ptr(index_dir) };
    let index_dir = index_dir.to_str().unwrap();
    let index_dir = PathBuf::from(index_dir);

    let index = Index::open_in_dir(index_dir).expect("Index not found");

    let reader = index.reader().expect("Reader cannot be found");

    unsafe {
        *s = State { reader: &reader };
    }

    true
}

#[no_mangle]
pub extern "C" fn deinit_search(s: *mut State) -> () {
    unsafe {
        assert!(!s.is_null(), "state is null");
        let s = &*s;
        let r = (&*s.reader).to_owned();
        std::mem::drop(r);
    }
}
