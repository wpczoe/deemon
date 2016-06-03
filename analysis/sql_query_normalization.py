import hashlib
import sqlparse


def remove_whitespaces(tree):
    if tree.is_group():
        tree.tokens = [remove_whitespaces(element) for element in tree.tokens if not element.is_whitespace()]

    return tree


def remove_rhs_values_sub(element):
    if type(element) is sqlparse.sql.Comparison:
        element.tokens.remove(element.right) #delete any value as this might be different to eq queries in diff context
        return element

    if type(element) is sqlparse.sql.Assignment:
        raise NameError('Unexpected assignment operator SQL')

    return element
    

def remove_rhs_values(tree):
    if tree.is_group():
        #print tree.tokens
        tree.tokens = [remove_rhs_values(element) for element in [remove_rhs_values_sub(element) for element in tree.tokens]]
        return tree #this return just looks pretty

    return tree

        
def order_alphabetically(tree):
    if tree.is_group():
        tree.tokens = sorted([order_alphabetically(element) for element in tree.tokens], key=lambda el: el.value)

    return tree


def normalize_query_syntax_tree(tree):
    return order_alphabetically(remove_rhs_values(remove_whitespaces(tree)))
    #return remove_rhs_values(remove_whitespaces(tree))
    #return remove_rhs_values(tree)

    
def generate_normalized_query_hash(query_string):
    return hashlib.md5(normalize_query_syntax_tree(sqlparse.parse(query_string)[0]).__str__()).hexdigest()


def generate_query_hash(query_string):
    return hashlib.md5(query_string).hexdigest()

