#include "wikixmlparser.h"
#include "rapidxml.hpp"
#include <iostream>
#include <string>
#include <unistd.h>

#define PARSE_PAGE_ERROR { false, nullptr, 0, nullptr, 0 }

WikiParseResult cParsePage(const char* rawXmlEntry)
{
    rapidxml::xml_document<> doc;

    try {
        doc.parse<rapidxml::parse_fastest>((char*)rawXmlEntry);
    } catch (const std::exception& e) {
        // TODO: Log error!
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

// int main()
// {
//     auto redirectXml = std::string("<page><redirect title=\"Blah\" />#REDIRECT</page>");
//     WikiParseResult wpr = parsePage(redirectXml.c_str());
//     if (wpr.is_redirect)
//         std::cout << "redirect!" << std::endl;
//     else
//         std::cout << "not redirect" << std::endl;
//     write(0, wpr.page_content, wpr.page_content_size);
//     std::cout << "\n\n";
//
//     auto articleXml = std::string("<page>Hello, World!</page>");
//     WikiParseResult wpr1 = parsePage(articleXml.c_str());
//     if (wpr1.is_redirect)
//         std::cout << "redirect!" << std::endl;
//     else
//         std::cout << "not redirect" << std::endl;
//     write(0, wpr1.page_content, wpr1.page_content_size);
//     std::cout << "\n\n";
// }