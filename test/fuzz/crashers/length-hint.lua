-- fuzz diff: a resized array part kept its old length hint; 5.5.1 starts
-- it at half the new size, so `#` of a table with holes found another
-- border. Printed 0 0; the reference prints 2 8.
print(#{nil, 2, nil, 4}, #{nil, 2, 3, 4, 5, 6, 7, 8})
