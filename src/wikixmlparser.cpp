#include "wikixmlparser.h"
#include "rapidxml.hpp"
#include <unistd.h>
// #include <iostream>

#define PARSE_PAGE_ERROR { false, nullptr, 0, nullptr, 0 }

WikiParseResult cParsePage(const char* rawXmlEntry)
{
    rapidxml::xml_document<> doc;

    try {
        doc.parse<rapidxml::parse_fastest>((char*)rawXmlEntry);
    } catch (const std::exception& e) {
        // std::cerr << "XML parse error" << std::endl;
        // std::cerr << e.what() << std::endl;
        return PARSE_PAGE_ERROR;
    }

    rapidxml::xml_node<>* pageNode = doc.first_node();
    if (!pageNode)
        return PARSE_PAGE_ERROR;

    bool is_redirect;
    if (pageNode->first_node("redirect") == nullptr) {
        is_redirect = false;
    } else {
        is_redirect = true;
    }

    // we only want 'mainspace' or ns='0' articles
    rapidxml::xml_node<>* namespaceNode = pageNode->first_node("ns");
    if (!namespaceNode) {
        // std::cerr << "No namespace found" << std::endl;
        return PARSE_PAGE_ERROR;
    }
    if (namespaceNode->value()[0] != '0') {
        // std::cerr << "Namespace " << namespaceNode->value()[0] << " found" << std::endl;
        return PARSE_PAGE_ERROR;
    }

    rapidxml::xml_node<>* titleNode = pageNode->first_node("title");
    if (!titleNode)
        return PARSE_PAGE_ERROR;

    rapidxml::xml_node<>* revNode = pageNode->first_node("revision");
    if (!revNode)
        return PARSE_PAGE_ERROR;

    rapidxml::xml_node<>* textNode = revNode->first_node("text");
    if (!textNode)
        return PARSE_PAGE_ERROR;

    return {
        is_redirect,
        titleNode->value(),
        titleNode->value_size(),
        textNode->value(),
        textNode->value_size(),
    };
}
