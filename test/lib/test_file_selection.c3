module libtorrent::file_selection_test;

import libtorrent::file_selection;
import std::io;

fn void test_create_from_string_valid() @test
{
    // Test parsing "0,2,4" with 5 total files
    FileSelection? result = file_selection::create_from_string("0,2,4", 5);
    if (catch err = result)
    {
        assert(false, "Should parse valid indices");
    }

    FileSelection selection = result;
    defer selection.free();

    assert(selection.total_files == 5, "Total files should be 5");
    assert(selection.is_file_selected(0), "File 0 should be selected");
    assert(!selection.is_file_selected(1), "File 1 should not be selected");
    assert(selection.is_file_selected(2), "File 2 should be selected");
    assert(!selection.is_file_selected(3), "File 3 should not be selected");
    assert(selection.is_file_selected(4), "File 4 should be selected");
}

fn void test_create_from_string_single_file() @test
{
    // Test selecting single file
    FileSelection selection = file_selection::create_from_string("3", 5)!!;
    defer selection.free();

    assert(selection.count_selected() == 1, "Should have 1 file selected");
    assert(selection.is_file_selected(3), "File 3 should be selected");
    assert(!selection.is_file_selected(0), "File 0 should not be selected");
}

fn void test_create_from_string_with_spaces() @test
{
    // Test parsing with spaces "0, 2, 4"
    FileSelection selection = file_selection::create_from_string("0, 2, 4", 5)!!;
    defer selection.free();

    assert(selection.is_file_selected(0), "File 0 should be selected");
    assert(selection.is_file_selected(2), "File 2 should be selected");
    assert(selection.is_file_selected(4), "File 4 should be selected");
}

fn void test_create_from_string_invalid_negative() @test
{
    // Test negative index
    if (catch err = file_selection::create_from_string("-1,0", 5))
    {
        // Expected to fail
    }
    else
    {
        assert(false, "Should reject negative indices");
    }
}

fn void test_create_from_string_invalid_out_of_bounds() @test
{
    // Test out of bounds index
    if (catch err = file_selection::create_from_string("0,5", 5))
    {
        // Expected to fail
    }
    else
    {
        assert(false, "Should reject out of bounds indices");
    }
}

fn void test_create_from_string_empty() @test
{
    // Test empty string
    if (catch err = file_selection::create_from_string("", 5))
    {
        // Expected to fail
    }
    else
    {
        assert(false, "Should reject empty string");
    }
}

fn void test_create_from_string_invalid_format() @test
{
    // Test invalid format (non-numeric)
    if (catch err = file_selection::create_from_string("0,abc,2", 5))
    {
        // Expected to fail
    }
    else
    {
        assert(false, "Should reject non-numeric indices");
    }
}

fn void test_create_from_string_zero_files() @test
{
    // Test with zero total files
    if (catch err = file_selection::create_from_string("0", 0))
    {
        // Expected to fail
    }
    else
    {
        assert(false, "Should reject zero total files");
    }
}

fn void test_create_all_selected() @test
{
    FileSelection selection = file_selection::create_all_selected(5);
    defer selection.free();

    assert(selection.total_files == 5, "Total files should be 5");
    assert(selection.is_all_selected(), "All files should be selected");
    assert(selection.count_selected() == 5, "Should have 5 files selected");

    for (usz i = 0; i < 5; i++)
    {
        assert(selection.is_file_selected(i), "File should be selected");
    }
}

fn void test_is_file_selected_out_of_bounds() @test
{
    FileSelection selection = file_selection::create_all_selected(3);
    defer selection.free();

    assert(!selection.is_file_selected(10), "Out of bounds should return false");
}

fn void test_is_all_selected_partial() @test
{
    FileSelection selection = file_selection::create_from_string("0,2", 5)!!;
    defer selection.free();

    assert(!selection.is_all_selected(), "Partial selection should not be all selected");
}

fn void test_count_selected() @test
{
    FileSelection selection = file_selection::create_from_string("1,3,4", 6)!!;
    defer selection.free();

    assert(selection.count_selected() == 3, "Should have 3 files selected");
}

fn void test_to_string_serialization() @test
{
    FileSelection selection = file_selection::create_from_string("0,2,4", 5)!!;
    defer selection.free();

    String serialized = selection.to_string();
    defer free(serialized);

    assert(serialized == "0,2,4", "Serialization should match original");
}

fn void test_to_string_roundtrip() @test
{
    String original = "1,3,5,7";

    FileSelection selection = file_selection::create_from_string(original, 10)!!;
    defer selection.free();

    String serialized = selection.to_string();
    defer free(serialized);

    // Parse again
    FileSelection selection2 = file_selection::create_from_string(serialized, 10)!!;
    defer selection2.free();

    // Should have same selections
    for (usz i = 0; i < 10; i++)
    {
        assert(selection.is_file_selected(i) == selection2.is_file_selected(i),
               "Roundtrip should preserve selections");
    }
}

fn void test_duplicate_indices() @test
{
    // Test duplicate indices (should handle gracefully)
    FileSelection selection = file_selection::create_from_string("0,2,0,2", 5)!!;
    defer selection.free();

    assert(selection.count_selected() == 2, "Should have 2 unique files selected");
    assert(selection.is_file_selected(0), "File 0 should be selected");
    assert(selection.is_file_selected(2), "File 2 should be selected");
}
